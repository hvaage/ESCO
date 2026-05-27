insert into public.external_data_sources (
  source_key, provider, title, source_url, version, license, metadata
)
values
  (
    'ssb_salary_tables',
    'SSB',
    'SSB salary tables for career market insight',
    'https://www.ssb.no/statbank/list/lonnansatt',
    null,
    'CC BY 4.0',
    jsonb_build_object(
      'tables',
      jsonb_build_array('11418', '11420', '11421'),
      'update_frequency',
      'annual',
      'import_status',
      'schema_ready'
    )
  )
on conflict (source_key) do update set
  provider = excluded.provider,
  title = excluded.title,
  source_url = excluded.source_url,
  license = excluded.license,
  metadata = public.external_data_sources.metadata || excluded.metadata;

create or replace function public.get_public_salary_profile(
  filter_industry_slug text default null,
  filter_nace_code text default null,
  education_level text default null,
  age_group text default null,
  gender text default '0',
  sector text default 'ALLE',
  working_time text default '0'
)
returns jsonb
language plpgsql
stable
as $$
declare
  industry_filter text;
  nace_filter text;
  selected_industry record;
  selected_nace record;
  selected_gender text;
  selected_sector text;
  selected_working_time text;
  selected_education text;
  selected_age text;
  latest_11420 integer;
  latest_11421 integer;
  payload jsonb;
begin
  industry_filter := nullif(trim(filter_industry_slug), '');
  nace_filter := nullif(trim(filter_nace_code), '');
  selected_gender := coalesce(nullif(trim(gender), ''), '0');
  selected_sector := coalesce(nullif(trim(sector), ''), 'ALLE');
  selected_working_time := coalesce(nullif(trim(working_time), ''), '0');
  selected_education := nullif(trim(education_level), '');
  selected_age := nullif(trim(age_group), '');

  select i.slug, i.name_no
  into selected_industry
  from public.industries i
  where i.slug = industry_filter;

  if nace_filter is null and industry_filter is not null then
    select m.ssb_code, m.ssb_label, m.confidence
    into selected_nace
    from public.industry_ssb_mappings m
    where m.industry_slug = industry_filter
      and m.ssb_dimension = 'NACE2007'
      and m.mapping_type = 'nace2007'
      and m.ssb_table_id in ('12850', '11420', '11421')
    order by
      case when m.ssb_table_id in ('11420', '11421') then 1 else 0 end desc,
      m.confidence desc,
      length(m.ssb_code),
      m.ssb_code
    limit 1;
    nace_filter := selected_nace.ssb_code;
  elsif nace_filter is not null then
    select m.ssb_code, max(m.ssb_label) as ssb_label, max(m.confidence) as confidence
    into selected_nace
    from public.industry_ssb_mappings m
    where m.ssb_dimension = 'NACE2007'
      and m.ssb_code = nace_filter
    group by m.ssb_code;
  end if;

  if nace_filter is null then
    return jsonb_build_object(
      'found', false,
      'schema_version', 'salary_profile.v1',
      'empty_state', jsonb_build_object(
        'title', 'Velg bransje for å se lønnsprofil',
        'message', 'Lønn etter utdanning og alder vises per næring. Velg en bransje eller send en NACE-kode.'
      ),
      'education_series', '[]'::jsonb,
      'age_series', '[]'::jsonb,
      'method_notes', jsonb_build_array(
        'SSB tabell 11420 viser lønn etter utdanningsnivå og næring.',
        'SSB tabell 11421 viser lønn etter alder og næring.',
        'SSB publiserer ikke alder og utdanning kombinert i disse tabellene.'
      )
    );
  end if;

  select max(period_year)
  into latest_11420
  from public.ssb_observations
  where table_id = '11420';

  select max(period_year)
  into latest_11421
  from public.ssb_observations
  where table_id = '11421';

  with education_rows as (
    select
      o.dimension_codes->>'UtdanNivaa' as code,
      o.dimension_labels->>'UtdanNivaa' as label,
      o.dimension_codes->>'MaaleMetode' as statistic_code,
      o.value,
      o.period_year
    from public.ssb_observations o
    where o.table_id = '11420'
      and o.period_year = latest_11420
      and o.metric_code = 'Manedslonn'
      and o.dimension_codes->>'NACE2007' = nace_filter
      and o.dimension_codes->>'Sektor' = selected_sector
      and o.dimension_codes->>'Kjonn' = selected_gender
      and o.dimension_codes->>'ArbeidsTid' = selected_working_time
      and o.dimension_codes->>'MaaleMetode' in ('01', '02', '051', '061', '10')
  ),
  education_pivot as (
    select
      code,
      max(label) as label,
      max(period_year) as year,
      max(value) filter (where statistic_code = '01') as median_salary,
      max(value) filter (where statistic_code = '02') as average_salary,
      max(value) filter (where statistic_code = '051') as lower_quartile_salary,
      max(value) filter (where statistic_code = '061') as upper_quartile_salary,
      max(value) filter (where statistic_code = '10') as employment_count
    from education_rows
    group by code
  ),
  education_selected as (
    select *
    from education_pivot
    order by
      case code
        when 'Ialt' then 0
        when '1-2' then 1
        when '3-5' then 2
        when '6' then 3
        when '7-8' then 4
        else 99
      end,
      code
  ),
  age_rows as (
    select
      o.dimension_codes->>'Alder' as code,
      o.dimension_labels->>'Alder' as label,
      o.dimension_codes->>'MaaleMetode' as statistic_code,
      o.value,
      o.period_year
    from public.ssb_observations o
    where o.table_id = '11421'
      and o.period_year = latest_11421
      and o.metric_code = 'Manedslonn'
      and o.dimension_codes->>'NACE2007' = nace_filter
      and o.dimension_codes->>'Sektor' = selected_sector
      and o.dimension_codes->>'Kjonn' = selected_gender
      and o.dimension_codes->>'ArbeidsTid' = selected_working_time
      and o.dimension_codes->>'MaaleMetode' in ('01', '02', '051', '061', '10')
  ),
  age_pivot as (
    select
      code,
      max(label) as label,
      max(period_year) as year,
      max(value) filter (where statistic_code = '01') as median_salary,
      max(value) filter (where statistic_code = '02') as average_salary,
      max(value) filter (where statistic_code = '051') as lower_quartile_salary,
      max(value) filter (where statistic_code = '061') as upper_quartile_salary,
      max(value) filter (where statistic_code = '10') as employment_count
    from age_rows
    group by code
  ),
  age_selected as (
    select *
    from age_pivot
    order by
      case code
        when '999' then 0
        when '00-24' then 1
        when '25-29' then 2
        when '30-34' then 3
        when '35-39' then 4
        when '40-44' then 5
        when '45-49' then 6
        when '50-54' then 7
        when '55-59' then 8
        when '60-' then 9
        else 99
      end,
      code
  ),
  education_series as (
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'code', code,
          'label', label,
          'year', year,
          'median_salary', median_salary,
          'average_salary', average_salary,
          'lower_quartile_salary', lower_quartile_salary,
          'upper_quartile_salary', upper_quartile_salary,
          'employment_count', employment_count,
          'is_selected', selected_education is not null and code = selected_education
        )
        order by
          case code
            when 'Ialt' then 0
            when '1-2' then 1
            when '3-5' then 2
            when '6' then 3
            when '7-8' then 4
            else 99
          end,
          code
      ),
      '[]'::jsonb
    ) as items
    from education_selected
  ),
  age_series as (
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'code', code,
          'label', label,
          'year', year,
          'median_salary', median_salary,
          'average_salary', average_salary,
          'lower_quartile_salary', lower_quartile_salary,
          'upper_quartile_salary', upper_quartile_salary,
          'employment_count', employment_count,
          'is_selected', selected_age is not null and code = selected_age
        )
        order by
          case code
            when '999' then 0
            when '00-24' then 1
            when '25-29' then 2
            when '30-34' then 3
            when '35-39' then 4
            when '40-44' then 5
            when '45-49' then 6
            when '50-54' then 7
            when '55-59' then 8
            when '60-' then 9
            else 99
          end,
          code
      ),
      '[]'::jsonb
    ) as items
    from age_selected
  ),
  education_kpi as (
    select to_jsonb(x) as item
    from (
      select *
      from education_pivot
      where code = coalesce(selected_education, 'Ialt')
      limit 1
    ) x
  ),
  age_kpi as (
    select to_jsonb(x) as item
    from (
      select *
      from age_pivot
      where code = coalesce(selected_age, '999')
      limit 1
    ) x
  ),
  all_education_kpi as (
    select to_jsonb(x) as item
    from (
      select *
      from education_pivot
      where code = 'Ialt'
      limit 1
    ) x
  )
  select jsonb_build_object(
    'found',
      jsonb_array_length((select items from education_series)) > 0
      or jsonb_array_length((select items from age_series)) > 0,
    'schema_version', 'salary_profile.v1',
    'filters', jsonb_build_object(
      'industry_slug', industry_filter,
      'industry_name', selected_industry.name_no,
      'nace_code', nace_filter,
      'nace_label', selected_nace.ssb_label,
      'education_level', selected_education,
      'age_group', selected_age,
      'gender', selected_gender,
      'sector', selected_sector,
      'working_time', selected_working_time
    ),
    'summary', jsonb_build_object(
      'title', 'Lønn i relevante bransjer',
      'description', 'Offisielle SSB-tall for månedslønn etter utdanningsnivå og alder i valgt næring.'
    ),
    'kpis', jsonb_build_object(
      'industry_median', (select item from all_education_kpi),
      'education_median', (select item from education_kpi),
      'age_median', (select item from age_kpi)
    ),
    'education_series', (select items from education_series),
    'age_series', (select items from age_series),
    'method_notes', jsonb_build_array(
      'SSB tabell 11420 viser lønn etter utdanningsnivå og næring.',
      'SSB tabell 11421 viser lønn etter alder og næring.',
      'SSB publiserer ikke alder og utdanning kombinert i disse tabellene. Vis derfor tallene som to separate sammenligninger.'
    ),
    'data_sources', jsonb_build_array(
      jsonb_build_object(
        'provider', 'SSB',
        'name', 'SSB tabell 11420',
        'title', 'Månedslønn etter utdanningsnivå og næring',
        'description', 'Månedslønn etter statistikkmål, sektor, utdanningsnivå, næring, kjønn, arbeidstid og år.'
      ),
      jsonb_build_object(
        'provider', 'SSB',
        'name', 'SSB tabell 11421',
        'title', 'Månedslønn etter alder og næring',
        'description', 'Månedslønn etter statistikkmål, sektor, næring, alder, kjønn, arbeidstid og år.'
      )
    )
  )
  into payload;

  return payload;
end;
$$;

grant execute on function public.get_public_salary_profile(text, text, text, text, text, text, text) to anon, authenticated;
