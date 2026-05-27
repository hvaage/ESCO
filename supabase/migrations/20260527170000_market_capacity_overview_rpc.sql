drop materialized view if exists public.mv_styrk_market_capacity;
create materialized view public.mv_styrk_market_capacity as
select *
from public.v_styrk_market_capacity;

create unique index if not exists mv_styrk_market_capacity_styrk_idx
  on public.mv_styrk_market_capacity(styrk_code);
create index if not exists mv_styrk_market_capacity_shortage_idx
  on public.mv_styrk_market_capacity(shortage_count desc)
  where shortage_count is not null;
create index if not exists mv_styrk_market_capacity_unemployed_idx
  on public.mv_styrk_market_capacity(unemployed_count desc)
  where unemployed_count is not null;
create index if not exists mv_styrk_market_capacity_vacancy_idx
  on public.mv_styrk_market_capacity(vacancy_count desc)
  where vacancy_count is not null;
create index if not exists mv_styrk_market_capacity_tightness_idx
  on public.mv_styrk_market_capacity(shortage_to_unemployed_ratio desc)
  where shortage_to_unemployed_ratio is not null;
create index if not exists mv_styrk_market_capacity_salary_idx
  on public.mv_styrk_market_capacity(salary_median_all desc)
  where salary_median_all is not null;

grant select on public.mv_styrk_market_capacity to anon, authenticated;

create or replace function public.get_public_market_capacity_overview(
  segment text default 'shortage',
  result_limit integer default 8
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
  payload jsonb;
begin
  requested_segment := lower(coalesce(nullif(trim(segment), ''), 'shortage'));
  safe_limit := greatest(1, least(coalesce(result_limit, 8), 50));

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

  with base as (
    select
      v.*,
      case segment_key
        when 'shortage' then v.shortage_count
        when 'unemployed' then v.unemployed_count
        when 'vacancies' then v.vacancy_count
        when 'tightness' then v.shortage_to_unemployed_ratio
        when 'salary' then v.salary_median_all
        else v.shortage_count
      end as segment_value
    from public.mv_styrk_market_capacity v
    where v.styrk_title is not null
      and (
        (segment_key = 'shortage' and v.shortage_count is not null)
        or (segment_key = 'unemployed' and v.unemployed_count is not null)
        or (segment_key = 'vacancies' and v.vacancy_count is not null)
        or (
          segment_key = 'tightness'
          and v.shortage_to_unemployed_ratio is not null
          and v.shortage_count is not null
          and coalesce(v.unemployed_count, 0) > 0
        )
        or (segment_key = 'salary' and v.salary_median_all is not null)
      )
  ),
  limited as (
    select *
    from base
    order by segment_value desc nulls last, styrk_title
    limit safe_limit
  ),
  periods as (
    select
      max(shortage_year) as shortage_year,
      max(unemployment_period) as unemployment_period,
      max(vacancies_period) as vacancies_period,
      max(salary_year) as salary_year
    from limited
  )
  select jsonb_build_object(
    'found', exists(select 1 from limited),
    'schema_version', 'market_capacity_overview.v1',
    'requested_segment', requested_segment,
    'segment', segment_key,
    'segment_label', segment_label,
    'summary', jsonb_build_object(
      'title', 'Arbeidsmarkedet akkurat nå',
      'description', 'Indikatorer for mangel, ledighet, ledige stillinger og månedslønn per yrke.'
    ),
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
        else 'NAV helt ledige ' || (select unemployment_period from periods)
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
          'segment_value', segment_value,
          'available_sources', available_sources
        )
        order by segment_value desc nulls last, styrk_title
      )
      from limited
    ), '[]'::jsonb),
    'data_sources', jsonb_build_array(
      jsonb_build_object(
        'provider', 'NAV',
        'title', 'NAV Bedriftsundersøkelsen',
        'description', 'Estimert mangel på arbeidskraft.'
      ),
      jsonb_build_object(
        'provider', 'NAV',
        'title', 'NAV helt ledige',
        'description', 'Registrerte helt ledige per yrke.'
      ),
      jsonb_build_object(
        'provider', 'NAV',
        'title', 'NAV ledige stillinger',
        'description', 'Tilgang ledige stillinger per yrke.'
      ),
      jsonb_build_object(
        'provider', 'SSB',
        'title', 'SSB tabell 11418',
        'description', 'Yrkesfordelt månedslønn.'
      )
    ),
    'confidence_notes', jsonb_build_array(
      'Tallene er indikatorer, ikke garanti for enkeltpersoner.',
      'NAV-mangel, ledighet og stillingstilgang kan være publisert på litt ulikt yrkesnivå.',
      'Lønnstall er månedslønn fra SSB og kan mangle for små yrker eller enkelte sektorer.'
    )
  )
  into payload;

  return payload;
end;
$$;

grant execute on function public.get_public_market_capacity_overview(text, integer) to anon, authenticated;
