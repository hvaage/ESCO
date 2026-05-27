create or replace function public.get_public_market_capacity(
  search_text text default null,
  result_limit integer default 20
)
returns jsonb
language sql
stable
as $$
  with params as (
    select
      nullif(trim(search_text), '') as q,
      nullif(trim(search_text), '') like 'http://data.europa.eu/esco/occupation/%' as is_esco_occupation_uri,
      greatest(1, least(coalesce(result_limit, 20), 50)) as safe_limit
  ),
  matched_occupations as (
    select
      e.uri as occupation_uri,
      coalesce(e.title_no, e.title_en, e.title) as occupation_title,
      e.uri = p.q as exact_match,
      greatest(
        case when e.uri = p.q then 1 else 0 end,
        case
          when p.q is null or p.is_esco_occupation_uri then 0
          else extensions.similarity(coalesce(e.title_no, e.title_en, e.title, ''), p.q)
        end
      ) as match_score
    from public.esco_entities e
    cross join params p
    where e.entity_type = 'occupation'
      and (
        p.q is null
        or (p.is_esco_occupation_uri and e.uri = p.q)
        or (
          not p.is_esco_occupation_uri
          and (
            e.uri = p.q
            or extensions.similarity(coalesce(e.title_no, e.title_en, e.title, ''), p.q) > 0.08
          )
        )
      )
  ),
  limited_occupations as (
    select mo.*
    from matched_occupations mo
    cross join params p
    order by mo.exact_match desc, mo.match_score desc, mo.occupation_title
    limit case when (select q from params) is null then 5000 else (select safe_limit from params) * 6 end
  ),
  matched as (
    select
      mo.occupation_uri,
      mo.occupation_title,
      mo.exact_match,
      mo.match_score,
      jsonb_agg(
        distinct jsonb_build_object(
          'styrk_code', c.styrk_code,
          'styrk_title', c.styrk_title,
          'shortage_year', c.shortage_year,
          'shortage_count', c.shortage_count,
          'shortage_ci_lower', c.shortage_ci_lower,
          'shortage_ci_upper', c.shortage_ci_upper,
          'tightness_indicator', c.tightness_indicator,
          'unemployment_period', c.unemployment_period,
          'unemployed_count', c.unemployed_count,
          'vacancies_period', c.vacancies_period,
          'vacancy_count', c.vacancy_count,
          'salary_year', c.salary_year,
          'salary_median_all', c.salary_median_all,
          'salary_q1_all', c.salary_q1_all,
          'salary_q3_all', c.salary_q3_all,
          'salary_average_all', c.salary_average_all,
          'salary_median_private', c.salary_median_private,
          'salary_median_state', c.salary_median_state,
          'salary_median_municipal', c.salary_median_municipal,
          'shortage_to_unemployed_ratio', c.shortage_to_unemployed_ratio,
          'vacancy_to_unemployed_ratio', c.vacancy_to_unemployed_ratio
        )
      ) filter (where c.styrk_code is not null) as styrk_market_signals,
      max(c.shortage_year) as shortage_year,
      max(c.shortage_count) as shortage_count,
      max(c.shortage_ci_lower) as shortage_ci_lower,
      max(c.shortage_ci_upper) as shortage_ci_upper,
      max(c.tightness_indicator) as tightness_indicator,
      max(c.unemployment_period) as unemployment_period,
      max(c.unemployed_count) as unemployed_count,
      max(c.vacancies_period) as vacancies_period,
      max(c.vacancy_count) as vacancy_count,
      max(c.salary_year) as salary_year,
      max(c.salary_median_all) as salary_median_all,
      max(c.salary_q1_all) as salary_q1_all,
      max(c.salary_q3_all) as salary_q3_all,
      max(c.salary_average_all) as salary_average_all,
      max(c.salary_median_private) as salary_median_private,
      max(c.salary_median_state) as salary_median_state,
      max(c.salary_median_municipal) as salary_median_municipal,
      max(c.shortage_to_unemployed_ratio) as shortage_to_unemployed_ratio,
      max(c.vacancy_to_unemployed_ratio) as vacancy_to_unemployed_ratio
    from limited_occupations mo
    join public.esco_styrk_mappings m on m.occupation_uri = mo.occupation_uri
    left join public.mv_styrk_market_capacity c on c.styrk_code = m.styrk_code
    where m.styrk_code ~ '^[0-9]{4}$'
    group by mo.occupation_uri, mo.occupation_title, mo.exact_match, mo.match_score
  ),
  enriched as (
    select
      *,
      (
        shortage_count is not null
        or unemployed_count is not null
        or vacancy_count is not null
        or salary_median_all is not null
      ) as has_market_data
    from matched
  ),
  limited as (
    select *
    from enriched
    where has_market_data
    order by exact_match desc, match_score desc, coalesce(shortage_count, 0) desc, occupation_title
    limit (select safe_limit from params)
  )
  select jsonb_build_object(
    'found', exists(select 1 from limited),
    'schema_version', 'market_capacity.v2',
    'items', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'occupation_uri', occupation_uri,
          'title', occupation_title,
          'has_market_data', has_market_data,
          'shortage_year', shortage_year,
          'shortage_count', shortage_count,
          'shortage_ci_lower', shortage_ci_lower,
          'shortage_ci_upper', shortage_ci_upper,
          'tightness_indicator', tightness_indicator,
          'unemployment_period', unemployment_period,
          'unemployed_count', unemployed_count,
          'vacancies_period', vacancies_period,
          'vacancy_count', vacancy_count,
          'salary_year', salary_year,
          'salary_median_all', salary_median_all,
          'salary_q1_all', salary_q1_all,
          'salary_q3_all', salary_q3_all,
          'salary_average_all', salary_average_all,
          'salary_median_private', salary_median_private,
          'salary_median_state', salary_median_state,
          'salary_median_municipal', salary_median_municipal,
          'shortage_to_unemployed_ratio', shortage_to_unemployed_ratio,
          'vacancy_to_unemployed_ratio', vacancy_to_unemployed_ratio,
          'styrk_market_signals', coalesce(styrk_market_signals, '[]'::jsonb)
        )
        order by exact_match desc, match_score desc, coalesce(shortage_count, 0) desc, occupation_title
      )
      from limited
    ), '[]'::jsonb),
    'data_sources', jsonb_build_array(
      jsonb_build_object(
        'provider', 'NAV',
        'name', 'NAV Bedriftsundersøkelsen',
        'title', 'NAV Bedriftsundersøkelsen',
        'description', 'Estimert mangel på arbeidskraft per yrke.'
      ),
      jsonb_build_object(
        'provider', 'NAV',
        'name', 'NAV helt ledige',
        'title', 'NAV helt ledige',
        'description', 'Registrerte helt ledige per yrke.'
      ),
      jsonb_build_object(
        'provider', 'NAV',
        'name', 'NAV ledige stillinger',
        'title', 'NAV ledige stillinger',
        'description', 'Tilgang ledige stillinger per yrke.'
      ),
      jsonb_build_object(
        'provider', 'SSB',
        'name', 'SSB tabell 11418',
        'title', 'SSB tabell 11418',
        'description', 'Yrkesfordelt månedslønn.'
      )
    ),
    'confidence_notes', jsonb_build_array(
      'NAV-mangel og NAV-ledighet kobles til STYRK der yrkeskode eller trygg navne-mapping finnes.',
      'SSB-lønn er månedslønn etter STYRK, sektor og statistikkmål.',
      'Dette er markedsindikatorer, ikke prognoser for enkeltpersoner.'
    )
  );
$$;

grant execute on function public.get_public_market_capacity(text, integer) to anon, authenticated;
