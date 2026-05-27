create table if not exists public.nav_source_files (
  id bigserial primary key,
  source_key text references public.external_data_sources(source_key) on delete set null,
  dataset_key text not null check (
    dataset_key in (
      'unemployment_monthly',
      'vacancies_monthly',
      'business_survey'
    )
  ),
  source_page_url text,
  attachment_url text not null,
  file_name text not null,
  file_period text,
  file_year integer,
  file_month integer check (file_month is null or (file_month between 1 and 12)),
  sha256 text not null,
  bytes integer,
  metadata jsonb not null default '{}'::jsonb,
  imported_at timestamptz not null default now(),
  unique (dataset_key, sha256)
);

create index if not exists nav_source_files_dataset_period_idx
  on public.nav_source_files(dataset_key, file_year desc, file_month desc);

create table if not exists public.nav_occupation_mappings (
  id bigserial primary key,
  nav_label text not null,
  nav_label_norm text not null,
  nav_code text,
  styrk_code text references public.styrk08(code) on delete set null,
  styrk_prefix text,
  mapping_level text not null check (
    mapping_level in ('exact_styrk4', 'styrk_prefix', 'aggregate_label', 'unmapped')
  ) default 'unmapped',
  confidence numeric(5,4) not null default 0.5000 check (confidence >= 0 and confidence <= 1),
  source text not null default 'import',
  notes text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (nav_label_norm, nav_code)
);

drop trigger if exists set_nav_occupation_mappings_updated_at on public.nav_occupation_mappings;
create trigger set_nav_occupation_mappings_updated_at
before update on public.nav_occupation_mappings
for each row execute function public.set_updated_at();

create index if not exists nav_occupation_mappings_styrk_idx
  on public.nav_occupation_mappings(styrk_code, styrk_prefix);
create index if not exists nav_occupation_mappings_label_trgm_idx
  on public.nav_occupation_mappings using gin (nav_label extensions.gin_trgm_ops);

create table if not exists public.nav_monthly_occupation_stats (
  observation_key text primary key,
  source_file_id bigint not null references public.nav_source_files(id) on delete cascade,
  dataset_key text not null check (dataset_key in ('unemployment_monthly', 'vacancies_monthly')),
  metric_code text not null,
  metric_label text,
  period text not null,
  period_year integer not null,
  period_month integer not null check (period_month between 1 and 12),
  nav_occupation_label text not null,
  nav_occupation_code text,
  nav_occupation_group_label text,
  styrk_code text references public.styrk08(code) on delete set null,
  styrk_prefix text,
  region_code text,
  region_label text,
  dimension_type text,
  dimension_label text,
  value numeric,
  suppressed boolean not null default false,
  metadata jsonb not null default '{}'::jsonb,
  imported_at timestamptz not null default now()
);

create index if not exists nav_monthly_stats_dataset_period_idx
  on public.nav_monthly_occupation_stats(dataset_key, period_year desc, period_month desc, metric_code);
create index if not exists nav_monthly_stats_styrk_idx
  on public.nav_monthly_occupation_stats(styrk_code, styrk_prefix);
create index if not exists nav_monthly_stats_region_idx
  on public.nav_monthly_occupation_stats(region_code);

create table if not exists public.nav_labour_shortage_survey (
  observation_key text primary key,
  source_file_id bigint not null references public.nav_source_files(id) on delete cascade,
  year integer not null,
  dimension_type text not null check (
    dimension_type in (
      'occupation',
      'occupation_group',
      'industry',
      'county',
      'education',
      'education_county',
      'industry_county',
      'barometer',
      'ai',
      'other'
    )
  ),
  label text not null,
  parent_label text,
  styrk_code text references public.styrk08(code) on delete set null,
  styrk_prefix text,
  nace_code text,
  region_code text,
  region_label text,
  education_level text,
  education_field text,
  shortage_count numeric,
  ci_lower numeric,
  ci_upper numeric,
  tightness_indicator numeric,
  serious_recruitment_problem_percent numeric,
  value numeric,
  metric_code text,
  metric_label text,
  metadata jsonb not null default '{}'::jsonb,
  imported_at timestamptz not null default now()
);

create index if not exists nav_shortage_year_dimension_idx
  on public.nav_labour_shortage_survey(year desc, dimension_type);
create index if not exists nav_shortage_styrk_idx
  on public.nav_labour_shortage_survey(styrk_code, styrk_prefix);
create index if not exists nav_shortage_region_idx
  on public.nav_labour_shortage_survey(region_code);

insert into public.external_data_sources (
  source_key, provider, title, source_url, version, license, metadata
)
values
  (
    'nav_unemployment_monthly',
    'NAV',
    'NAV helt ledige etter yrke',
    'https://www.nav.no/no/nav-og-samfunn/statistikk/arbeidssokere-og-stillinger-statistikk/helt-ledige',
    null,
    null,
    jsonb_build_object('update_frequency', 'monthly', 'import_status', 'schema_ready')
  ),
  (
    'nav_vacancies_monthly',
    'NAV',
    'NAV tilgang ledige stillinger etter yrke',
    'https://www.nav.no/no/nav-og-samfunn/statistikk/arbeidssokere-og-stillinger-statistikk/ledige-stillinger',
    null,
    null,
    jsonb_build_object('update_frequency', 'monthly', 'import_status', 'schema_ready')
  ),
  (
    'nav_business_survey',
    'NAV',
    'NAV bedriftsundersøkelsen',
    'https://www.nav.no/no/nav-og-samfunn/kunnskap/analyser-fra-nav/arbeid-og-velferd/arbeid-og-velferd/bedriftsundersokelsen',
    null,
    null,
    jsonb_build_object('update_frequency', 'annual', 'import_status', 'schema_ready')
  ),
  (
    'ssb_salary_tables',
    'SSB',
    'SSB salary tables for career market insight',
    'https://data.ssb.no/api/v0/no/table/11418',
    null,
    'CC BY 4.0',
    jsonb_build_object('tables', jsonb_build_array('11418'), 'update_frequency', 'annual', 'import_status', 'schema_ready')
  )
on conflict (source_key) do update set
  provider = excluded.provider,
  title = excluded.title,
  source_url = excluded.source_url,
  license = excluded.license,
  metadata = public.external_data_sources.metadata || excluded.metadata;

create or replace view public.v_styrk_market_capacity as
with latest_shortage as (
  select distinct on (s.styrk_code)
    s.styrk_code,
    s.styrk_prefix,
    s.year as shortage_year,
    s.shortage_count,
    s.ci_lower as shortage_ci_lower,
    s.ci_upper as shortage_ci_upper,
    s.tightness_indicator
  from public.nav_labour_shortage_survey s
  where s.dimension_type = 'occupation'
    and s.styrk_code is not null
  order by s.styrk_code, s.year desc
),
latest_unemployment as (
  select distinct on (u.styrk_code)
    u.styrk_code,
    u.period as unemployment_period,
    u.value as unemployed_count
  from public.nav_monthly_occupation_stats u
  where u.dataset_key = 'unemployment_monthly'
    and u.metric_code = 'count'
    and u.styrk_code is not null
    and u.dimension_type is null
  order by
    u.styrk_code,
    u.period_year desc,
    u.period_month desc,
    coalesce((u.metadata->>'source_priority')::integer, 0) desc
),
latest_vacancies as (
  select distinct on (v.styrk_code)
    v.styrk_code,
    v.period as vacancies_period,
    v.value as vacancy_count
  from public.nav_monthly_occupation_stats v
  where v.dataset_key = 'vacancies_monthly'
    and v.metric_code = 'count'
    and v.styrk_code is not null
    and v.dimension_type is null
  order by
    v.styrk_code,
    v.period_year desc,
    v.period_month desc,
    coalesce((v.metadata->>'source_priority')::integer, 0) desc
),
salary_latest as (
  select
    o.dimension_codes->>'Yrke' as styrk_code,
    max(o.period_year) as salary_year
  from public.ssb_observations o
  where o.table_id = '11418'
    and o.metric_code = 'Manedslonn'
    and o.dimension_codes->>'Kjonn' = '0'
    and o.dimension_codes->>'AvtaltVanlig' = '0'
    and o.dimension_codes->>'Yrke' ~ '^[0-9]{4}$'
  group by o.dimension_codes->>'Yrke'
),
salary_pivot as (
  select
    o.dimension_codes->>'Yrke' as styrk_code,
    sl.salary_year,
    max(o.value) filter (
      where o.dimension_codes->>'MaaleMetode' = '01'
        and o.dimension_codes->>'Sektor' = 'ALLE'
    ) as salary_median_all,
    max(o.value) filter (
      where o.dimension_codes->>'MaaleMetode' = '051'
        and o.dimension_codes->>'Sektor' = 'ALLE'
    ) as salary_q1_all,
    max(o.value) filter (
      where o.dimension_codes->>'MaaleMetode' = '061'
        and o.dimension_codes->>'Sektor' = 'ALLE'
    ) as salary_q3_all,
    max(o.value) filter (
      where o.dimension_codes->>'MaaleMetode' = '02'
        and o.dimension_codes->>'Sektor' = 'ALLE'
    ) as salary_average_all,
    max(o.value) filter (
      where o.dimension_codes->>'MaaleMetode' = '01'
        and o.dimension_codes->>'Sektor' = 'A+B+D+E'
    ) as salary_median_private,
    max(o.value) filter (
      where o.dimension_codes->>'MaaleMetode' = '01'
        and o.dimension_codes->>'Sektor' = '6100'
    ) as salary_median_state,
    max(o.value) filter (
      where o.dimension_codes->>'MaaleMetode' = '01'
        and o.dimension_codes->>'Sektor' = '6500'
    ) as salary_median_municipal
  from public.ssb_observations o
  join salary_latest sl
    on sl.styrk_code = o.dimension_codes->>'Yrke'
   and sl.salary_year = o.period_year
  where o.table_id = '11418'
    and o.metric_code = 'Manedslonn'
    and o.dimension_codes->>'Kjonn' = '0'
    and o.dimension_codes->>'AvtaltVanlig' = '0'
  group by o.dimension_codes->>'Yrke', sl.salary_year
)
select
  s.code as styrk_code,
  s.name as styrk_title,
  s.level as styrk_level,
  ls.shortage_year,
  ls.shortage_count,
  ls.shortage_ci_lower,
  ls.shortage_ci_upper,
  ls.tightness_indicator,
  lu.unemployment_period,
  lu.unemployed_count,
  lv.vacancies_period,
  lv.vacancy_count,
  sp.salary_year,
  sp.salary_median_all,
  sp.salary_q1_all,
  sp.salary_q3_all,
  sp.salary_average_all,
  sp.salary_median_private,
  sp.salary_median_state,
  sp.salary_median_municipal,
  round((ls.shortage_count / nullif(lu.unemployed_count, 0))::numeric, 3) as shortage_to_unemployed_ratio,
  round((lv.vacancy_count / nullif(lu.unemployed_count, 0))::numeric, 3) as vacancy_to_unemployed_ratio,
  jsonb_build_object(
    'nav_shortage', ls.shortage_year is not null,
    'nav_unemployment', lu.unemployment_period is not null,
    'nav_vacancies', lv.vacancies_period is not null,
    'ssb_salary', sp.salary_year is not null
  ) as available_sources
from public.styrk08 s
left join latest_shortage ls on ls.styrk_code = s.code
left join lateral (
  select
    u.period as unemployment_period,
    u.value as unemployed_count
  from public.nav_monthly_occupation_stats u
  where u.dataset_key = 'unemployment_monthly'
    and u.metric_code = 'count'
    and u.dimension_type is null
    and (
      u.styrk_code = s.code
      or (
        u.styrk_prefix is not null
        and s.code like (u.styrk_prefix || '%')
      )
    )
  order by
    case when u.styrk_code = s.code then 1 else 0 end desc,
    length(coalesce(u.styrk_prefix, '')) desc,
    u.period_year desc,
    u.period_month desc,
    coalesce((u.metadata->>'source_priority')::integer, 0) desc
  limit 1
) lu on true
left join lateral (
  select
    v.period as vacancies_period,
    v.value as vacancy_count
  from public.nav_monthly_occupation_stats v
  where v.dataset_key = 'vacancies_monthly'
    and v.metric_code = 'count'
    and v.dimension_type is null
    and (
      v.styrk_code = s.code
      or (
        v.styrk_prefix is not null
        and s.code like (v.styrk_prefix || '%')
      )
    )
  order by
    case when v.styrk_code = s.code then 1 else 0 end desc,
    length(coalesce(v.styrk_prefix, '')) desc,
    v.period_year desc,
    v.period_month desc,
    coalesce((v.metadata->>'source_priority')::integer, 0) desc
  limit 1
) lv on true
left join salary_pivot sp on sp.styrk_code = s.code
where s.level = 4;

create or replace view public.v_esco_market_capacity as
select
  m.occupation_uri,
  max(coalesce(e.title_no, e.title_en, e.title)) as occupation_title,
  jsonb_agg(
    distinct jsonb_build_object(
      'styrk_code', c.styrk_code,
      'styrk_title', c.styrk_title,
      'shortage_count', c.shortage_count,
      'unemployed_count', c.unemployed_count,
      'vacancy_count', c.vacancy_count,
      'salary_median_all', c.salary_median_all,
      'salary_median_private', c.salary_median_private,
      'salary_median_state', c.salary_median_state,
      'salary_median_municipal', c.salary_median_municipal
    )
  ) filter (where c.styrk_code is not null) as styrk_market_signals,
  max(c.shortage_count) as shortage_count,
  max(c.unemployed_count) as unemployed_count,
  max(c.vacancy_count) as vacancy_count,
  max(c.salary_median_all) as salary_median_all,
  max(c.salary_median_private) as salary_median_private,
  max(c.salary_median_state) as salary_median_state,
  max(c.salary_median_municipal) as salary_median_municipal,
  max(c.shortage_to_unemployed_ratio) as shortage_to_unemployed_ratio,
  max(c.vacancy_to_unemployed_ratio) as vacancy_to_unemployed_ratio
from public.esco_styrk_mappings m
join public.esco_entities e on e.uri = m.occupation_uri
left join public.v_styrk_market_capacity c on c.styrk_code = m.styrk_code
where m.styrk_code ~ '^[0-9]{4}$'
group by m.occupation_uri;

create or replace function public.get_public_market_capacity(
  search_text text default null,
  result_limit integer default 20
)
returns jsonb
language sql
stable
as $$
  with matched_occupations as (
    select
      e.uri as occupation_uri,
      coalesce(e.title_no, e.title_en, e.title) as occupation_title,
      greatest(
        case
          when search_text is null or length(trim(search_text)) = 0 then 0
          else extensions.similarity(coalesce(e.title_no, e.title_en, e.title, ''), search_text)
        end,
        case
          when search_text is null or length(trim(search_text)) = 0 then 0
          else extensions.similarity(coalesce(e.uri, ''), search_text)
        end
      ) as match_score
    from public.esco_entities e
    where search_text is null
       or length(trim(search_text)) = 0
       or e.uri = search_text
       or extensions.similarity(coalesce(e.title_no, e.title_en, e.title, ''), search_text) > 0.08
  ),
  limited_occupations as (
    select *
    from matched_occupations
    order by match_score desc, occupation_title
    limit case
      when search_text is null or length(trim(search_text)) = 0 then 5000
      else greatest(1, least(coalesce(result_limit, 20), 50)) * 4
    end
  ),
  matched as (
    select
      mo.occupation_uri,
      mo.occupation_title,
      mo.match_score,
      jsonb_agg(
        distinct jsonb_build_object(
          'styrk_code', c.styrk_code,
          'styrk_title', c.styrk_title,
          'shortage_count', c.shortage_count,
          'unemployed_count', c.unemployed_count,
          'vacancy_count', c.vacancy_count,
          'salary_median_all', c.salary_median_all,
          'salary_median_private', c.salary_median_private,
          'salary_median_state', c.salary_median_state,
          'salary_median_municipal', c.salary_median_municipal
        )
      ) filter (where c.styrk_code is not null) as styrk_market_signals,
      max(c.shortage_count) as shortage_count,
      max(c.unemployed_count) as unemployed_count,
      max(c.vacancy_count) as vacancy_count,
      max(c.salary_median_all) as salary_median_all,
      max(c.salary_median_private) as salary_median_private,
      max(c.salary_median_state) as salary_median_state,
      max(c.salary_median_municipal) as salary_median_municipal,
      max(c.shortage_to_unemployed_ratio) as shortage_to_unemployed_ratio,
      max(c.vacancy_to_unemployed_ratio) as vacancy_to_unemployed_ratio
    from limited_occupations mo
    join public.esco_styrk_mappings m on m.occupation_uri = mo.occupation_uri
    left join public.v_styrk_market_capacity c on c.styrk_code = m.styrk_code
    where m.styrk_code ~ '^[0-9]{4}$'
    group by mo.occupation_uri, mo.occupation_title, mo.match_score
  )
  select jsonb_build_object(
    'found', exists(select 1 from matched),
    'schema_version', 'market_capacity.v1',
    'items', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'occupation_uri', occupation_uri,
          'title', occupation_title,
          'shortage_count', shortage_count,
          'unemployed_count', unemployed_count,
          'vacancy_count', vacancy_count,
          'salary_median_all', salary_median_all,
          'salary_median_private', salary_median_private,
          'salary_median_state', salary_median_state,
          'salary_median_municipal', salary_median_municipal,
          'shortage_to_unemployed_ratio', shortage_to_unemployed_ratio,
          'vacancy_to_unemployed_ratio', vacancy_to_unemployed_ratio,
          'styrk_market_signals', styrk_market_signals
        )
        order by match_score desc, coalesce(shortage_count, 0) desc, occupation_title
      )
      from (
        select *
        from matched
        order by match_score desc, coalesce(shortage_count, 0) desc, occupation_title
        limit greatest(1, least(coalesce(result_limit, 20), 50))
      ) limited
    ), '[]'::jsonb),
    'data_sources', jsonb_build_array(
      jsonb_build_object('provider', 'NAV', 'title', 'Bedriftsundersøkelsen, helt ledige og ledige stillinger'),
      jsonb_build_object('provider', 'SSB', 'title', 'Yrkesfordelt månedslønn')
    ),
    'confidence_notes', jsonb_build_array(
      'NAV-mangel og NAV-ledighet kobles til STYRK der yrkeskode eller trygg navne-mapping finnes.',
      'SSB-lønn er månedslønn etter STYRK, sektor og statistikkmål.',
      'Dette er markedsindikatorer, ikke prognoser for enkeltpersoner.'
    )
  );
$$;

grant select on public.nav_source_files to authenticated;
grant select on public.nav_occupation_mappings to authenticated;
grant select on public.nav_monthly_occupation_stats to authenticated;
grant select on public.nav_labour_shortage_survey to authenticated;
grant select on public.v_styrk_market_capacity to anon, authenticated;
grant select on public.v_esco_market_capacity to anon, authenticated;
grant execute on function public.get_public_market_capacity(text, integer) to anon, authenticated;
