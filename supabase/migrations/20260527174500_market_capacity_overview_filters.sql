drop function if exists public.get_public_market_capacity_overview(text, integer);
drop function if exists public.get_public_market_capacity_overview(text, integer, text, text);

create or replace function public.get_public_market_capacity_overview(
  segment text default 'shortage',
  result_limit integer default 8,
  filter_region_code text default null,
  filter_industry_slug text default null
)
returns jsonb
language plpgsql
stable
as $$
declare
  requested_segment text;
  segment_key text;
  segment_label text;
  safe_limit integer;
  region_filter text;
  industry_filter text;
  selected_region_label text;
  selected_industry_name text;
  payload jsonb;
begin
  requested_segment := lower(coalesce(nullif(trim(segment), ''), 'shortage'));
  safe_limit := greatest(1, least(coalesce(result_limit, 8), 50));
  region_filter := nullif(trim(filter_region_code), '');
  industry_filter := nullif(trim(filter_industry_slug), '');

  segment_key := case
    when requested_segment in ('shortage', 'storst_mangel', 'størst_mangel', 'mangel') then 'shortage'
    when requested_segment in ('unemployed', 'flest_ledige', 'helt_ledige', 'arbeidsledighet') then 'unemployed'
    when requested_segment in ('vacancies', 'flest_ledige_stillinger', 'ledige_stillinger') then 'vacancies'
    when requested_segment in ('tightness', 'strammest_marked', 'markedsbalanse') then 'tightness'
    when requested_segment in ('salary', 'hoyest_lonn', 'høyest_lønn', 'lonn', 'lønn') then 'salary'
    else 'shortage'
  end;

  segment_label := case segment_key
    when 'shortage' then 'Størst mangel'
    when 'unemployed' then 'Flest helt ledige'
    when 'vacancies' then 'Flest ledige stillinger'
    when 'tightness' then 'Strammest marked'
    when 'salary' then 'Høyest lønn'
    else 'Størst mangel'
  end;

  select i.name_no
  into selected_industry_name
  from public.industries i
  where i.slug = industry_filter;

  select coalesce(
    (
      select max(n.region_label)
      from public.nav_monthly_occupation_stats n
      where n.region_code = region_filter
    ),
    case region_filter
      when '03' then 'Oslo'
      when '11' then 'Rogaland'
      when '15' then 'Møre og Romsdal'
      when '18' then 'Nordland'
      when '30' then 'Viken'
      when '31' then 'Østfold'
      when '32' then 'Akershus'
      when '33' then 'Buskerud'
      when '34' then 'Innlandet'
      when '38' then 'Vestfold og Telemark'
      when '39' then 'Vestfold'
      when '40' then 'Telemark'
      when '42' then 'Agder'
      when '46' then 'Vestland'
      when '50' then 'Trøndelag'
      when '54' then 'Troms og Finnmark'
      when '55' then 'Troms'
      when '56' then 'Finnmark'
      else null
    end
  )
  into selected_region_label;

  with industry_styrk as (
    select distinct m.styrk_code
    from public.occupation_industries oi
    join public.esco_styrk_mappings m
      on m.occupation_uri = oi.occupation_uri
    where industry_filter is not null
      and oi.industry_slug = industry_filter
      and m.styrk_code ~ '^[0-9]{4}$'
  ),
  base as (
    select
      v.*,
      ru.regional_unemployment_period,
      ru.regional_unemployed_count,
      ru.regional_unemployment_region_code,
      ru.regional_unemployment_region_label,
      ru.regional_unemployment_match_level,
      ru.regional_unemployment_styrk_prefix,
      case
        when region_filter is not null and ru.regional_unemployed_count is not null then ru.regional_unemployed_count
        else v.unemployed_count
      end as display_unemployed_count,
      case
        when region_filter is not null and ru.regional_unemployment_period is not null then ru.regional_unemployment_period
        else v.unemployment_period
      end as display_unemployment_period,
      case
        when region_filter is not null and ru.regional_unemployed_count is not null then 'regional'
        else 'national'
      end as unemployment_scope,
      case
        when region_filter is not null and ru.regional_unemployed_count is not null
          then round((v.shortage_count / nullif(ru.regional_unemployed_count, 0))::numeric, 3)
        else v.shortage_to_unemployed_ratio
      end as display_shortage_to_unemployed_ratio,
      case
        when region_filter is not null and ru.regional_unemployed_count is not null
          then round((v.vacancy_count / nullif(ru.regional_unemployed_count, 0))::numeric, 3)
        else v.vacancy_to_unemployed_ratio
      end as display_vacancy_to_unemployed_ratio
    from public.mv_styrk_market_capacity v
    left join lateral (
      select
        u.period as regional_unemployment_period,
        u.value as regional_unemployed_count,
        u.region_code as regional_unemployment_region_code,
        coalesce(
          u.region_label,
          split_part(coalesce(u.dimension_label, u.nav_occupation_group_label), ' - ', 1)
        ) as regional_unemployment_region_label,
        case
          when u.styrk_code = v.styrk_code then 'exact_styrk4'
          when u.styrk_prefix is not null then 'styrk_prefix'
          else 'unmapped'
        end as regional_unemployment_match_level,
        u.styrk_prefix as regional_unemployment_styrk_prefix
      from public.nav_monthly_occupation_stats u
      where region_filter is not null
        and u.dataset_key = 'unemployment_monthly'
        and u.metric_code = 'count'
        and u.dimension_type = 'county'
        and (
          u.region_code = region_filter
          or (
            selected_region_label is not null
            and regexp_replace(
              lower(split_part(coalesce(u.region_label, u.dimension_label, u.nav_occupation_group_label, ''), ' - ', 1)),
              '\s+',
              ' ',
              'g'
            ) = regexp_replace(lower(selected_region_label), '\s+', ' ', 'g')
          )
        )
        and (
          u.styrk_code = v.styrk_code
          or (
            u.styrk_prefix is not null
            and length(u.styrk_prefix) >= 2
            and v.styrk_code like (u.styrk_prefix || '%')
          )
        )
      order by
        case when u.styrk_code = v.styrk_code then 1 else 0 end desc,
        length(coalesce(u.styrk_prefix, '')) desc,
        u.period_year desc,
        u.period_month desc,
        coalesce((u.metadata->>'source_priority')::integer, 0) desc
      limit 1
    ) ru on true
    where v.styrk_title is not null
      and (
        industry_filter is null
        or exists (
          select 1
          from industry_styrk ist
          where ist.styrk_code = v.styrk_code
        )
      )
  ),
  scored as (
    select
      b.*,
      case
        when region_filter is not null
          and segment_key in ('unemployed', 'tightness')
          and b.unemployment_scope = 'regional'
          then 1
        when region_filter is null
          then 1
        else 0
      end as regional_sort_priority,
      case segment_key
        when 'shortage' then b.shortage_count
        when 'unemployed' then b.display_unemployed_count
        when 'vacancies' then b.vacancy_count
        when 'tightness' then b.display_shortage_to_unemployed_ratio
        when 'salary' then b.salary_median_all
        else b.shortage_count
      end as segment_value
    from base b
    where (
        segment_key = 'shortage'
        and b.shortage_count is not null
      )
      or (
        segment_key = 'unemployed'
        and b.display_unemployed_count is not null
      )
      or (
        segment_key = 'vacancies'
        and b.vacancy_count is not null
      )
      or (
        segment_key = 'tightness'
        and b.display_shortage_to_unemployed_ratio is not null
        and b.shortage_count is not null
        and coalesce(b.display_unemployed_count, 0) > 0
      )
      or (
        segment_key = 'salary'
        and b.salary_median_all is not null
      )
  ),
  limited as (
    select *
    from scored
    order by regional_sort_priority desc, segment_value desc nulls last, styrk_title
    limit safe_limit
  ),
  periods as (
    select
      max(shortage_year) as shortage_year,
      max(display_unemployment_period) as unemployment_period,
      max(vacancies_period) as vacancies_period,
      max(salary_year) as salary_year,
      bool_or(unemployment_scope = 'regional') as has_regional_unemployment
    from limited
  ),
  regional_group_latest_period as (
    select max(u.period_year * 100 + u.period_month) as period_key
    from public.nav_monthly_occupation_stats u
    where region_filter is not null
      and u.dataset_key = 'unemployment_monthly'
      and u.metric_code = 'count'
      and u.dimension_type = 'county'
      and (
        u.region_code = region_filter
        or (
          selected_region_label is not null
          and regexp_replace(
            lower(split_part(coalesce(u.region_label, u.dimension_label, u.nav_occupation_group_label, ''), ' - ', 1)),
            '\s+',
            ' ',
            'g'
          ) = regexp_replace(lower(selected_region_label), '\s+', ' ', 'g')
        )
      )
  ),
  regional_group_rows as (
    select
      u.nav_occupation_label as label,
      u.period,
      u.value,
      coalesce(
        u.region_label,
        split_part(coalesce(u.dimension_label, u.nav_occupation_group_label), ' - ', 1)
      ) as region_label,
      u.region_code,
      u.metadata->>'mapping_level' as mapping_level
    from public.nav_monthly_occupation_stats u
    join regional_group_latest_period lp
      on lp.period_key = u.period_year * 100 + u.period_month
    where region_filter is not null
      and u.dataset_key = 'unemployment_monthly'
      and u.metric_code = 'count'
      and u.dimension_type = 'county'
      and u.value is not null
      and lower(u.nav_occupation_label) not like 'i alt%'
      and (
        u.region_code = region_filter
        or (
          selected_region_label is not null
          and regexp_replace(
            lower(split_part(coalesce(u.region_label, u.dimension_label, u.nav_occupation_group_label, ''), ' - ', 1)),
            '\s+',
            ' ',
            'g'
          ) = regexp_replace(lower(selected_region_label), '\s+', ' ', 'g')
        )
      )
    order by u.value desc nulls last, u.nav_occupation_label
    limit 8
  ),
  regional_groups as (
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'label', label,
          'period', period,
          'value', value,
          'region_code', region_code,
          'region_label', region_label,
          'mapping_level', mapping_level,
          'scope', 'broad_nav_occupation_group'
        )
        order by value desc nulls last, label
      ),
      '[]'::jsonb
    ) as items
    from regional_group_rows
  )
  select jsonb_build_object(
    'found', exists(select 1 from limited),
    'schema_version', 'market_capacity_overview.v2',
    'requested_segment', requested_segment,
    'segment', segment_key,
    'segment_label', segment_label,
    'summary', jsonb_build_object(
      'title', 'Arbeidsmarkedet akkurat nå',
      'description', 'Indikatorer for mangel, ledighet, ledige stillinger og månedslønn per yrke.'
    ),
    'applied_filters', jsonb_build_object(
      'region_code', region_filter,
      'region_label', selected_region_label,
      'industry_slug', industry_filter,
      'industry_name', selected_industry_name,
      'is_filtered', region_filter is not null or industry_filter is not null
    ),
    'scope', jsonb_build_object(
      'industry_filter_applied', industry_filter is not null,
      'industry_scope', case
        when industry_filter is not null then 'occupation_industry_mapping'
        else 'all_occupations'
      end,
      'region_filter_applied', region_filter is not null,
      'regional_unemployment_available', coalesce((select has_regional_unemployment from periods), false),
      'regional_unemployment_group_available', jsonb_array_length(coalesce((select items from regional_groups), '[]'::jsonb)) > 0,
      'shortage_scope', 'national',
      'unemployment_scope', case
        when coalesce((select has_regional_unemployment from periods), false) then 'regional_where_available'
        else 'national'
      end,
      'vacancy_scope', 'national',
      'salary_scope', 'national'
    ),
    'scope_note', case
      when industry_filter is not null and region_filter is not null then
        case
          when coalesce((select has_regional_unemployment from periods), false) then
            'Yrkeslisten er avgrenset til valgt bransje. Regional ledighet brukes der NAV-data finnes; mangel, ledige stillinger og lønn er nasjonale indikatorer.'
          when jsonb_array_length(coalesce((select items from regional_groups), '[]'::jsonb)) > 0 then
            'Yrkeslisten er avgrenset til valgt bransje. NAV har regionale ledighetstall på brede yrkesgrupper for valgt område, men ikke nok detalj til sikker STYRK-4-sortering. Yrkeslisten bruker derfor nasjonale yrkestall.'
          else
            'Yrkeslisten er avgrenset til valgt bransje. Vi har ikke regional NAV-ledighet på detaljert yrkesnivå for valgt område; markedstallene er nasjonale indikatorer.'
        end
      when industry_filter is not null then
        'Yrkeslisten er avgrenset til valgt bransje. Markedstallene er nasjonale indikatorer.'
      when region_filter is not null then
        case
          when coalesce((select has_regional_unemployment from periods), false) then
            'Regional ledighet brukes der NAV-data finnes; mangel, ledige stillinger og lønn er nasjonale indikatorer.'
          when jsonb_array_length(coalesce((select items from regional_groups), '[]'::jsonb)) > 0 then
            'NAV har regionale ledighetstall på brede yrkesgrupper for valgt område, men ikke nok detalj til sikker STYRK-4-sortering. Yrkeslisten bruker derfor nasjonale yrkestall.'
          else
            'Vi har ikke regional NAV-ledighet på detaljert yrkesnivå for valgt område; yrkeslisten bruker nasjonale indikatorer.'
        end
      else
        'Nasjonal oversikt per yrke.'
    end,
    'regional_unemployment_groups', coalesce((select items from regional_groups), '[]'::jsonb),
    'source_periods', jsonb_build_object(
      'shortage_year', (select shortage_year from periods),
      'unemployment_period', (select unemployment_period from periods),
      'vacancies_period', (select vacancies_period from periods),
      'salary_year', (select salary_year from periods)
    ),
    'source_line_parts', jsonb_build_array(
      case
        when (select shortage_year from periods) is null then null
        else 'NAV Bedriftsundersøkelsen ' || (select shortage_year::text from periods)
      end,
      case
        when (select unemployment_period from periods) is null then null
        else 'NAV helt ledige ' || (select unemployment_period from periods) ||
          case when coalesce((select has_regional_unemployment from periods), false) then ' (regionalt der tilgjengelig)' else '' end
      end,
      case
        when (select vacancies_period from periods) is null then null
        else 'NAV ledige stillinger ' || (select vacancies_period from periods)
      end,
      case
        when (select salary_year from periods) is null then null
        else 'SSB lønn ' || (select salary_year::text from periods)
      end
    ),
    'items', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'styrk_code', styrk_code,
          'styrk_title', styrk_title,
          'shortage_year', shortage_year,
          'shortage_count', shortage_count,
          'shortage_ci_lower', shortage_ci_lower,
          'shortage_ci_upper', shortage_ci_upper,
          'shortage_scope', 'national',
          'tightness_indicator', tightness_indicator,
          'unemployment_period', display_unemployment_period,
          'unemployed_count', display_unemployed_count,
          'unemployment_scope', unemployment_scope,
          'national_unemployment_period', unemployment_period,
          'national_unemployed_count', unemployed_count,
          'regional_unemployment_period', regional_unemployment_period,
          'regional_unemployed_count', regional_unemployed_count,
          'regional_unemployment_region_code', regional_unemployment_region_code,
          'regional_unemployment_region_label', regional_unemployment_region_label,
          'regional_unemployment_match_level', regional_unemployment_match_level,
          'regional_unemployment_styrk_prefix', regional_unemployment_styrk_prefix,
          'vacancies_period', vacancies_period,
          'vacancy_count', vacancy_count,
          'vacancy_scope', 'national',
          'salary_year', salary_year,
          'salary_median_all', salary_median_all,
          'salary_q1_all', salary_q1_all,
          'salary_q3_all', salary_q3_all,
          'salary_average_all', salary_average_all,
          'salary_median_private', salary_median_private,
          'salary_median_state', salary_median_state,
          'salary_median_municipal', salary_median_municipal,
          'salary_scope', 'national',
          'shortage_to_unemployed_ratio', display_shortage_to_unemployed_ratio,
          'national_shortage_to_unemployed_ratio', shortage_to_unemployed_ratio,
          'vacancy_to_unemployed_ratio', display_vacancy_to_unemployed_ratio,
          'national_vacancy_to_unemployed_ratio', vacancy_to_unemployed_ratio,
          'segment_value', segment_value,
          'regional_sort_priority', regional_sort_priority,
          'available_sources', available_sources
        )
        order by regional_sort_priority desc, segment_value desc nulls last, styrk_title
      )
      from limited
    ), '[]'::jsonb),
    'data_sources', jsonb_build_array(
      jsonb_build_object(
        'provider', 'NAV',
        'name', 'NAV Bedriftsundersøkelsen',
        'title', 'NAV Bedriftsundersøkelsen',
        'description', 'Estimert mangel på arbeidskraft.'
      ),
      jsonb_build_object(
        'provider', 'NAV',
        'name', 'NAV helt ledige',
        'title', 'NAV helt ledige',
        'description', 'Registrerte helt ledige per yrke. Vises regionalt der slike data finnes.'
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
    'confidence_notes',
      jsonb_build_array(
        'Tallene er indikatorer, ikke garanti for enkeltpersoner.',
        'NAV-mangel, ledighet og stillingstilgang kan være publisert på litt ulikt yrkesnivå.',
        'Lønnstall er månedslønn fra SSB og kan mangle for små yrker eller enkelte sektorer.'
      )
      || case
        when industry_filter is not null then jsonb_build_array(
          'Ved bransjefilter avgrenses yrkeslisten med ESCO/STYRK-bransjekoblinger. Selve NAV/SSB-tallene er nasjonale der ikke annet er merket.'
        )
        else '[]'::jsonb
      end
      || case
        when region_filter is not null then jsonb_build_array(
          'Ved regionfilter brukes regional NAV-ledighet der slike data finnes på tilstrekkelig yrkesnivå. Brede NAV-grupper vises som egne regionale gruppesignaler, ikke som eksakte STYRK-4-tall.'
        )
        else '[]'::jsonb
      end
  )
  into payload;

  return payload;
end;
$$;

grant execute on function public.get_public_market_capacity_overview(text, integer, text, text) to anon, authenticated;
