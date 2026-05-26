create table if not exists public.nho_kb_sources (
  source_id text primary key,
  year integer not null,
  group_type text,
  subgroup text,
  chapter text,
  classification text,
  title text,
  rows_including_header integer,
  data_rows integer,
  columns_count integer,
  header text,
  header_json jsonb,
  source_url text,
  page_url text,
  md5 text,
  bytes integer,
  imported_at timestamptz not null default now()
);

create table if not exists public.nho_kb_observations (
  id bigserial primary key,
  observation_key text not null unique,
  source_id text not null references public.nho_kb_sources(source_id) on delete cascade,
  year integer not null,
  group_type text,
  subgroup text,
  chapter text,
  classification text,
  page_url text,
  source_url text,
  source_file text,
  sheet text,
  xlsx_row_number integer,
  question text,
  subquestion text,
  breakdown_variable text,
  breakdown_value text,
  variable_name text,
  variable_label text,
  measure_name text,
  value_text text,
  value_numeric numeric,
  dimensions jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  imported_at timestamptz not null default now()
);

create index if not exists nho_kb_sources_group_idx
  on public.nho_kb_sources (year, group_type, subgroup, chapter);
create index if not exists nho_kb_sources_class_idx
  on public.nho_kb_sources (classification, chapter);
create index if not exists nho_kb_observations_source_idx
  on public.nho_kb_observations (source_id);
create index if not exists nho_kb_observations_group_idx
  on public.nho_kb_observations (year, group_type, subgroup, chapter);
create index if not exists nho_kb_observations_breakdown_idx
  on public.nho_kb_observations (year, breakdown_variable, breakdown_value);
create index if not exists nho_kb_observations_measure_idx
  on public.nho_kb_observations (measure_name);
create index if not exists nho_kb_observations_signal_idx
  on public.nho_kb_observations (classification, chapter, measure_name);
create index if not exists nho_kb_observations_dimensions_gin_idx
  on public.nho_kb_observations using gin (dimensions);
create index if not exists nho_kb_observations_question_trgm_idx
  on public.nho_kb_observations using gin (question extensions.gin_trgm_ops);
create index if not exists nho_kb_observations_subquestion_trgm_idx
  on public.nho_kb_observations using gin (subquestion extensions.gin_trgm_ops);

create table if not exists public.nho_kb_subgroup_mappings (
  id bigserial primary key,
  group_type text not null,
  subgroup text not null,
  label_no text not null,
  industry_slug text references public.industries(slug) on delete set null,
  region_code text,
  region_label text,
  mapping_scope text not null check (mapping_scope in ('industry', 'region', 'national')),
  confidence numeric(5,4) not null default 0.6500 check (confidence >= 0 and confidence <= 1),
  notes text,
  created_at timestamptz not null default now()
);

create index if not exists nho_kb_subgroup_mappings_lookup_idx
  on public.nho_kb_subgroup_mappings(group_type, subgroup);
create index if not exists nho_kb_subgroup_mappings_industry_idx
  on public.nho_kb_subgroup_mappings(industry_slug);
create index if not exists nho_kb_subgroup_mappings_region_idx
  on public.nho_kb_subgroup_mappings(region_code);
create unique index if not exists nho_kb_subgroup_mappings_unique_idx
  on public.nho_kb_subgroup_mappings(
    group_type,
    subgroup,
    mapping_scope,
    coalesce(industry_slug, ''),
    coalesce(region_code, '')
  );

insert into public.nho_kb_subgroup_mappings (
  group_type, subgroup, label_no, industry_slug, region_code, region_label,
  mapping_scope, confidence, notes
)
values
  ('Hovedrapport', 'Alle', 'Nasjonalt', null, null, 'Norge', 'national', 1.0000, 'Nasjonal hovedrapport.'),

  ('Fylke', 'Oslo', 'Oslo', null, '03', 'Oslo', 'region', 0.9500, 'SSB fylkeskode 2024/2025.'),
  ('Fylke', 'Akershus', 'Akershus', null, '32', 'Akershus', 'region', 0.9500, 'SSB fylkeskode 2024/2025.'),
  ('Fylke', 'Ostfold', 'Østfold', null, '31', 'Østfold', 'region', 0.9500, 'SSB fylkeskode 2024/2025.'),
  ('Fylke', 'Buskerud', 'Buskerud', null, '33', 'Buskerud', 'region', 0.9500, 'SSB fylkeskode 2024/2025.'),
  ('Fylke', 'Innlandet', 'Innlandet', null, '34', 'Innlandet', 'region', 0.9500, 'SSB fylkeskode 2024/2025.'),
  ('Fylke', 'Vestfold', 'Vestfold', null, '39', 'Vestfold', 'region', 0.9500, 'SSB fylkeskode 2024/2025.'),
  ('Fylke', 'Telemark', 'Telemark', null, '40', 'Telemark', 'region', 0.9500, 'SSB fylkeskode 2024/2025.'),
  ('Fylke', 'Agder', 'Agder', null, '42', 'Agder', 'region', 0.9500, 'SSB fylkeskode 2024/2025.'),
  ('Fylke', 'Rogaland', 'Rogaland', null, '11', 'Rogaland', 'region', 0.9500, 'SSB fylkeskode 2024/2025.'),
  ('Fylke', 'Vestland', 'Vestland', null, '46', 'Vestland', 'region', 0.9500, 'SSB fylkeskode 2024/2025.'),
  ('Fylke', 'More_og_Roms', 'Møre og Romsdal', null, '15', 'Møre og Romsdal', 'region', 0.9500, 'SSB fylkeskode 2024/2025.'),
  ('Fylke', 'Trondelag', 'Trøndelag', null, '50', 'Trøndelag', 'region', 0.9500, 'SSB fylkeskode 2024/2025.'),
  ('Fylke', 'Nordland', 'Nordland', null, '18', 'Nordland', 'region', 0.9500, 'SSB fylkeskode 2024/2025.'),
  ('Fylke', 'Troms', 'Troms', null, '55', 'Troms', 'region', 0.9500, 'SSB fylkeskode 2024/2025.'),
  ('Fylke', 'Finnmark', 'Finnmark', null, '56', 'Finnmark', 'region', 0.9500, 'SSB fylkeskode 2024/2025.'),

  ('Landsforening', 'Abelia', 'Abelia', 'it_teknologi', null, null, 'industry', 0.7000, 'Kunnskap, teknologi og rådgivning; sterkest brukt som IT/teknologi-signal.'),
  ('Landsforening', 'Finans_Norge', 'Finans Norge', 'okonomi_administrasjon', null, null, 'industry', 0.8500, 'Finans, forsikring og økonomi.'),
  ('Landsforening', 'Fornybar_Nor', 'Fornybar Norge', 'industri_produksjon', null, null, 'industry', 0.7000, 'Energi/fornybar, teknisk og industriell kompetanse.'),
  ('Landsforening', 'Mediebedrift', 'Mediebedriftenes Landsforening', 'kultur_media', null, null, 'industry', 0.8500, 'Media og innhold.'),
  ('Landsforening', 'NHO_Byggenar', 'NHO Byggenæringen', 'bygg_anlegg', null, null, 'industry', 0.9000, 'Bygg og anlegg.'),
  ('Landsforening', 'NHO_Elektro', 'NHO Elektro', 'bygg_anlegg', null, null, 'industry', 0.7500, 'Elektroinstallasjon og tekniske byggfag.'),
  ('Landsforening', 'NHO_Elektro', 'NHO Elektro', 'industri_produksjon', null, null, 'industry', 0.5500, 'Elektro overlapper også industri/produksjon.'),
  ('Landsforening', 'NHO_Geneo', 'NHO Geneo', 'helse_omsorg', null, null, 'industry', 0.8500, 'Helse, velferd og oppvekst.'),
  ('Landsforening', 'NHO_Logistik', 'NHO Logistikk og Transport', 'transport_logistikk', null, null, 'industry', 0.9000, 'Logistikk og transport.'),
  ('Landsforening', 'NHO_Luftfart', 'NHO Luftfart', 'transport_logistikk', null, null, 'industry', 0.8500, 'Luftfart som transportnæring.'),
  ('Landsforening', 'NHO_Mat_og_D', 'NHO Mat og Drikke', 'industri_produksjon', null, null, 'industry', 0.7500, 'Mat- og drikkeproduksjon.'),
  ('Landsforening', 'NHO_Reiseliv', 'NHO Reiseliv', 'reiseliv_servering', null, null, 'industry', 0.9000, 'Reiseliv, servering og overnatting.'),
  ('Landsforening', 'NHO_Service', 'NHO Service og Handel', 'salg_kundeservice', null, null, 'industry', 0.6500, 'Service og handel; bred og derfor moderat presisjon.'),
  ('Landsforening', 'NHO_Transpor', 'NHO Transport', 'transport_logistikk', null, null, 'industry', 0.9000, 'Transport.'),
  ('Landsforening', 'Norges_Bilbr', 'Norges Bilbransjeforbund', 'salg_kundeservice', null, null, 'industry', 0.6500, 'Bilhandel og kundedrevne roller.'),
  ('Landsforening', 'Norges_Bilbr', 'Norges Bilbransjeforbund', 'industri_produksjon', null, null, 'industry', 0.5500, 'Verksted/tekniske bilfag overlapper industri og produksjon.'),
  ('Landsforening', 'Norsk_Indust', 'Norsk Industri', 'industri_produksjon', null, null, 'industry', 0.9000, 'Industri og produksjon.'),
  ('Landsforening', 'Offshore_Nor', 'Offshore Norge', 'industri_produksjon', null, null, 'industry', 0.8000, 'Offshore/energi som teknisk-industrielt signal.'),
  ('Landsforening', 'Sjomat_Norge', 'Sjømat Norge', 'landbruk_fiskeri_havbruk', null, null, 'industry', 0.9000, 'Sjømat og havbruk.')
on conflict do nothing;

create or replace view public.v_nho_kb_observations_mapped as
select
  o.*,
  coalesce(m_breakdown.label_no, m_subgroup.label_no) as mapped_label_no,
  m_subgroup.industry_slug,
  i.name_no as industry_name_no,
  coalesce(m_breakdown.region_code, m_subgroup.region_code) as region_code,
  coalesce(m_breakdown.region_label, m_subgroup.region_label, o.breakdown_value) as region_label,
  coalesce(m_breakdown.mapping_scope, m_subgroup.mapping_scope) as mapping_scope,
  coalesce(m_breakdown.confidence, m_subgroup.confidence) as mapping_confidence
from public.nho_kb_observations o
left join public.nho_kb_subgroup_mappings m_subgroup
  on m_subgroup.group_type = o.group_type
 and m_subgroup.subgroup = o.subgroup
left join public.nho_kb_subgroup_mappings m_breakdown
  on o.breakdown_variable = 'Fylke'
 and m_breakdown.group_type = 'Fylke'
 and lower(extensions.unaccent(m_breakdown.label_no)) = lower(extensions.unaccent(replace(o.breakdown_value, E'\n', ' ')))
left join public.industries i on i.slug = m_subgroup.industry_slug;

create or replace view public.v_nho_unmet_need_signals as
with base as (
  select
    source_id,
    year,
    group_type,
    subgroup,
    classification,
    coalesce(nullif(breakdown_variable, ''), 'subgroup') as native_dimension,
    nullif(breakdown_value, '') as native_dimension_value,
    industry_slug,
    industry_name_no,
    region_code,
    region_label,
    mapping_scope,
    mapping_confidence,
    sum(value_numeric) filter (where measure_name in ('I noen grad', 'I noen grad (%)')) as some_need,
    sum(value_numeric) filter (where measure_name in ('I stor grad', 'I stor grad (%)')) as high_need,
    sum(value_numeric) filter (where measure_name in ('Ikke i det hele tatt', 'Ikke i det hele tatt (%)', 'I liten grad', 'I liten grad (%)', 'I noen grad', 'I noen grad (%)', 'I stor grad', 'I stor grad (%)')) as total_value,
    jsonb_agg(distinct source_id) as source_ids
  from public.v_nho_kb_observations_mapped
  where question = 'I hvilken grad har bedriften et udekket kompetansebehov i dag?'
    and value_numeric is not null
  group by
    source_id, year, group_type, subgroup, classification,
    coalesce(nullif(breakdown_variable, ''), 'subgroup'),
    nullif(breakdown_value, ''),
    industry_slug, industry_name_no, region_code, region_label, mapping_scope, mapping_confidence
)
select
  'nho_unmet_need'::text as signal_type,
  'Udekket kompetansebehov'::text as signal_label,
  year,
  group_type,
  subgroup,
  classification,
  native_dimension,
  native_dimension_value,
  industry_slug,
  industry_name_no,
  region_code,
  region_label,
  round(((coalesce(some_need, 0) + coalesce(high_need, 0)) / nullif(total_value, 0) * 100)::numeric, 2) as signal_value,
  round((coalesce(high_need, 0) / nullif(total_value, 0) * 100)::numeric, 2) as high_intensity_value,
  total_value as sample_base,
  mapping_scope,
  coalesce(mapping_confidence, 0.8000) as confidence,
  jsonb_build_object(
    'some_need', some_need,
    'high_need', high_need,
    'total_value', total_value,
    'source_ids', source_ids,
    'interpretation', 'andel som svarer i noen grad eller i stor grad'
  ) as metadata
from base
where total_value > 0;

create or replace view public.v_nho_competence_field_signals as
with base as (
  select
    source_id,
    year,
    group_type,
    subgroup,
    classification,
    subquestion as signal_label,
    coalesce(nullif(breakdown_variable, ''), 'subgroup') as native_dimension,
    nullif(breakdown_value, '') as native_dimension_value,
    industry_slug,
    industry_name_no,
    region_code,
    region_label,
    mapping_scope,
    mapping_confidence,
    sum(value_numeric) filter (where measure_name in ('Valgt', 'Valgt (%)')) as selected_value,
    sum(value_numeric) filter (where measure_name in ('Ikke valgt', 'Ikke valgt (%)', 'Valgt', 'Valgt (%)')) as total_value,
    jsonb_agg(distinct source_id) as source_ids
  from public.v_nho_kb_observations_mapped
  where question = 'Innen hvilke av de følgende fagområder har bedriften behov for kompetanse?'
    and subquestion is not null
    and subquestion <> ''
    and subquestion <> 'Ingen av de overstående'
    and value_numeric is not null
  group by
    source_id, year, group_type, subgroup, classification, subquestion,
    coalesce(nullif(breakdown_variable, ''), 'subgroup'),
    nullif(breakdown_value, ''),
    industry_slug, industry_name_no, region_code, region_label, mapping_scope, mapping_confidence
)
select
  'nho_competence_field_need'::text as signal_type,
  signal_label,
  year,
  group_type,
  subgroup,
  classification,
  native_dimension,
  native_dimension_value,
  industry_slug,
  industry_name_no,
  region_code,
  region_label,
  round((selected_value / nullif(total_value, 0) * 100)::numeric, 2) as signal_value,
  null::numeric as high_intensity_value,
  total_value as sample_base,
  mapping_scope,
  coalesce(mapping_confidence, 0.7500) as confidence,
  jsonb_build_object(
    'selected_value', selected_value,
    'total_value', total_value,
    'source_ids', source_ids,
    'interpretation', 'andel som har valgt fagområdet'
  ) as metadata
from base
where total_value > 0;

create or replace view public.v_nho_education_level_signals as
with base as (
  select
    source_id,
    year,
    group_type,
    subgroup,
    classification,
    replace(subquestion, E'\n', ' ') as signal_label,
    coalesce(nullif(breakdown_variable, ''), 'subgroup') as native_dimension,
    nullif(breakdown_value, '') as native_dimension_value,
    industry_slug,
    industry_name_no,
    region_code,
    region_label,
    mapping_scope,
    mapping_confidence,
    sum(value_numeric) filter (where measure_name in ('I noen grad', 'I noen grad (%)')) as some_need,
    sum(value_numeric) filter (where measure_name in ('I stor grad', 'I stor grad (%)')) as high_need,
    sum(value_numeric) filter (where measure_name in ('Ikke i det hele tatt', 'Ikke i det hele tatt (%)', 'I liten grad', 'I liten grad (%)', 'I noen grad', 'I noen grad (%)', 'I stor grad', 'I stor grad (%)')) as total_value,
    jsonb_agg(distinct source_id) as source_ids
  from public.v_nho_kb_observations_mapped
  where question = 'I hvilken grad har bedriften behov for personer med følgende utdanningsnivåer?'
    and subquestion is not null
    and subquestion <> ''
    and value_numeric is not null
  group by
    source_id, year, group_type, subgroup, classification, replace(subquestion, E'\n', ' '),
    coalesce(nullif(breakdown_variable, ''), 'subgroup'),
    nullif(breakdown_value, ''),
    industry_slug, industry_name_no, region_code, region_label, mapping_scope, mapping_confidence
)
select
  'nho_education_level_need'::text as signal_type,
  signal_label,
  year,
  group_type,
  subgroup,
  classification,
  native_dimension,
  native_dimension_value,
  industry_slug,
  industry_name_no,
  region_code,
  region_label,
  round(((coalesce(some_need, 0) + coalesce(high_need, 0)) / nullif(total_value, 0) * 100)::numeric, 2) as signal_value,
  round((coalesce(high_need, 0) / nullif(total_value, 0) * 100)::numeric, 2) as high_intensity_value,
  total_value as sample_base,
  mapping_scope,
  coalesce(mapping_confidence, 0.7000) as confidence,
  jsonb_build_object(
    'some_need', some_need,
    'high_need', high_need,
    'total_value', total_value,
    'source_ids', source_ids,
    'interpretation', 'andel som svarer i noen grad eller i stor grad'
  ) as metadata
from base
where total_value > 0;

create or replace view public.v_nho_skill_weight_signals as
with base as (
  select
    year,
    group_type,
    subgroup,
    classification,
    replace(variable_label, E'\n', ' ') as signal_label,
    industry_slug,
    industry_name_no,
    region_code,
    region_label,
    mapping_scope,
    mapping_confidence,
    avg(value_numeric) as average_points,
    count(*) as response_count,
    jsonb_agg(distinct source_id) as source_ids
  from public.v_nho_kb_observations_mapped
  where classification = 'ranking_long_values'
    and group_type = 'Hovedrapport'
    and measure_name = '.value'
    and variable_label is not null
    and variable_label <> ''
    and value_numeric is not null
  group by
    year, group_type, subgroup, classification, replace(variable_label, E'\n', ' '),
    industry_slug, industry_name_no, region_code, region_label, mapping_scope, mapping_confidence
)
select
  'nho_recruitment_skill_weight'::text as signal_type,
  signal_label,
  year,
  group_type,
  subgroup,
  classification,
  'subgroup'::text as native_dimension,
  subgroup as native_dimension_value,
  industry_slug,
  industry_name_no,
  region_code,
  region_label,
  round(average_points::numeric, 2) as signal_value,
  null::numeric as high_intensity_value,
  response_count::numeric as sample_base,
  mapping_scope,
  coalesce(mapping_confidence, 0.7500) as confidence,
  jsonb_build_object(
    'response_count', response_count,
    'source_ids', source_ids,
    'interpretation', 'gjennomsnittlig poengfordeling fra rangeringsdata'
  ) as metadata
from base;

create or replace view public.v_nho_compass_signals as
select * from public.v_nho_unmet_need_signals
union all
select * from public.v_nho_competence_field_signals
union all
select * from public.v_nho_education_level_signals
union all
select * from public.v_nho_skill_weight_signals;

create or replace view public.v_nho_compass_signals_ranked as
select
  s.*,
  row_number() over (
    partition by
      s.year,
      s.signal_type,
      coalesce(s.industry_slug, 'national'),
      coalesce(s.region_code, 'national')
    order by
      case when s.sample_base >= 30 then 0 else 1 end,
      s.signal_value desc nulls last,
      s.confidence desc
  ) as signal_rank
from public.v_nho_compass_signals s
where s.signal_value is not null
  and (s.mapping_scope is not null or s.group_type = 'Hovedrapport');

create or replace view public.v_nho_compass_signal_year_trends as
with yearly as (
  select
    signal_type,
    signal_label,
    group_type,
    subgroup,
    classification,
    native_dimension,
    native_dimension_value,
    industry_slug,
    industry_name_no,
    region_code,
    region_label,
    mapping_scope,
    year,
    round(avg(signal_value)::numeric, 2) as signal_value,
    round(avg(high_intensity_value)::numeric, 2) as high_intensity_value,
    sum(sample_base) as sample_base,
    max(confidence) as confidence,
    jsonb_agg(metadata) as source_metadata
  from public.v_nho_compass_signals
  where signal_value is not null
    and (mapping_scope is not null or group_type = 'Hovedrapport')
  group by
    signal_type,
    signal_label,
    group_type,
    subgroup,
    classification,
    native_dimension,
    native_dimension_value,
    industry_slug,
    industry_name_no,
    region_code,
    region_label,
    mapping_scope,
    year
),
with_previous as (
  select
    y.*,
    lag(y.year) over trend_window as previous_year,
    lag(y.signal_value) over trend_window as previous_signal_value
  from yearly y
  window trend_window as (
    partition by
      signal_type,
      signal_label,
      group_type,
      subgroup,
      classification,
      native_dimension,
      coalesce(native_dimension_value, ''),
      coalesce(industry_slug, ''),
      coalesce(region_code, '')
    order by year
  )
)
select
  *,
  round((signal_value - previous_signal_value)::numeric, 2) as signal_change,
  round(
    case
      when previous_signal_value is null or previous_signal_value = 0 then null
      else ((signal_value - previous_signal_value) / previous_signal_value) * 100
    end::numeric,
    2
  ) as signal_change_percent
from with_previous;

create or replace function public.get_public_career_compass(
  search_text text,
  filter_region_code text default null,
  filter_industry_slug text default null
)
returns jsonb
language plpgsql
stable
as $$
declare
  occupation record;
  industry_filter text[];
begin
  if filter_industry_slug is null or length(trim(filter_industry_slug)) = 0 then
    industry_filter := null;
  else
    industry_filter := array[filter_industry_slug];
  end if;

  select
    e.uri,
    e.title,
    e.title_no,
    e.title_en,
    e.description_no,
    1::real as search_score
  into occupation
  from public.esco_entities e
  where e.entity_type = 'occupation'
    and e.uri = search_text
  limit 1;

  if not found then
    select
      e.uri,
      e.title,
      e.title_no,
      e.title_en,
      e.description_no,
      1::real as search_score
    into occupation
    from public.esco_occupation_aliases a
    join public.esco_entities e on e.uri = a.occupation_uri
    where e.entity_type = 'occupation'
      and lower(extensions.unaccent(a.alias)) = lower(extensions.unaccent(search_text))
    order by a.weight desc, e.title_no asc nulls last
    limit 1;
  end if;

  if not found then
    select
      s.uri,
      s.title,
      s.title_no,
      s.title_en,
      e.description_no,
      s.score as search_score
    into occupation
    from public.search_esco_occupations(search_text, industry_filter, 1) s
    join public.esco_entities e on e.uri = s.uri
    limit 1;
  end if;

  if not found then
    return jsonb_build_object(
      'found', false,
      'query', search_text,
      'message', 'Fant ikke yrke/stilling i ESCO/STYRK-grunnlaget.'
    );
  end if;

  return jsonb_build_object(
    'found', true,
    'query', search_text,
    'occupation', jsonb_build_object(
      'uri', occupation.uri,
      'title', occupation.title,
      'title_no', occupation.title_no,
      'title_en', occupation.title_en,
      'description_no', occupation.description_no,
      'search_score', occupation.search_score
    ),
    'market_signal', coalesce((
      select to_jsonb(ms) - 'occupation_uri' - 'title_no' - 'title_en'
      from public.v_occupation_market_signals ms
      where ms.occupation_uri = occupation.uri
      limit 1
    ), '{}'::jsonb),
    'nho_metadata', jsonb_build_object(
      'latest_year', (select max(year) from public.nho_kb_sources),
      'available_years', coalesce((
        select jsonb_agg(year order by year)
        from (
          select distinct year
          from public.nho_kb_sources
          order by year
        ) years
      ), '[]'::jsonb),
      'historical_policy', 'NHO years are retained. The compass shows the latest imported year by default; use trend views for year-over-year development.'
    ),
    'industries', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'slug', x.industry_slug,
          'name_no', x.industry_name_no,
          'confidence', x.confidence,
          'source', x.source
        )
        order by x.confidence desc, x.industry_name_no
      )
      from (
        select *
        from public.v_occupation_industries
        where occupation_uri = occupation.uri
        order by confidence desc, weight desc
        limit 6
      ) x
    ), '[]'::jsonb),
    'industry_signals', coalesce((
      select jsonb_agg(to_jsonb(x) - 'industry_slug' order by x.employed_latest desc)
      from (
        select distinct ins.*
        from public.v_industry_national_signals ins
        join public.occupation_industries oi
          on oi.industry_slug = ins.industry_slug
        where oi.occupation_uri = occupation.uri
        order by ins.employed_latest desc
        limit 6
      ) x
    ), '[]'::jsonb),
    'regional_signals', coalesce((
      select jsonb_agg(to_jsonb(x) - 'occupation_uri' order by x.relevance_score desc)
      from (
        select *
        from public.v_occupation_regional_signals
        where occupation_uri = occupation.uri
          and (
            filter_region_code is null
            or length(trim(filter_region_code)) = 0
            or region_code = filter_region_code
          )
        order by relevance_score desc, employed_latest desc
        limit 10
      ) x
    ), '[]'::jsonb),
    'skills', jsonb_build_object(
      'essential', coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'uri', x.uri,
            'title_no', x.title_no,
            'title_en', x.title_en,
            'skill_type', x.skill_type
          )
          order by x.title_no
        )
        from (
          select sk.uri, sk.title_no, sk.title_en, coalesce(os.skill_type, sk.skill_type) as skill_type
          from public.esco_occupation_skills os
          join public.esco_entities sk on sk.uri = os.skill_uri
          where os.occupation_uri = occupation.uri
            and os.relation_type = 'essential'
          order by sk.title_no asc nulls last
          limit 30
        ) x
      ), '[]'::jsonb),
      'optional', coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'uri', x.uri,
            'title_no', x.title_no,
            'title_en', x.title_en,
            'skill_type', x.skill_type
          )
          order by x.title_no
        )
        from (
          select sk.uri, sk.title_no, sk.title_en, coalesce(os.skill_type, sk.skill_type) as skill_type
          from public.esco_occupation_skills os
          join public.esco_entities sk on sk.uri = os.skill_uri
          where os.occupation_uri = occupation.uri
            and os.relation_type = 'optional'
          order by sk.title_no asc nulls last
          limit 30
        ) x
      ), '[]'::jsonb)
    ),
    'related_occupations', coalesce((
      select jsonb_agg(to_jsonb(r) order by r.overlap_score desc, r.overlap_count desc)
      from public.get_related_occupations(occupation.uri, 8) r
    ), '[]'::jsonb),
    'learn_next', jsonb_build_object(
      'start_with', coalesce((
        select jsonb_agg(jsonb_build_object('uri', x.uri, 'title_no', x.title_no) order by x.title_no)
        from (
          select sk.uri, sk.title_no
          from public.esco_occupation_skills os
          join public.esco_entities sk on sk.uri = os.skill_uri
          where os.occupation_uri = occupation.uri
            and os.relation_type = 'essential'
          order by sk.title_no asc nulls last
          limit 8
        ) x
      ), '[]'::jsonb),
      'then_consider', coalesce((
        select jsonb_agg(jsonb_build_object('uri', x.uri, 'title_no', x.title_no) order by x.title_no)
        from (
          select sk.uri, sk.title_no
          from public.esco_occupation_skills os
          join public.esco_entities sk on sk.uri = os.skill_uri
          where os.occupation_uri = occupation.uri
            and os.relation_type = 'optional'
          order by sk.title_no asc nulls last
          limit 8
        ) x
      ), '[]'::jsonb)
    ),
    'nho_signals', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'signal_type', n.signal_type,
          'signal_label', n.signal_label,
          'signal_value', n.signal_value,
          'high_intensity_value', n.high_intensity_value,
          'signal_rank', n.signal_rank,
          'period', n.year,
          'group_type', n.group_type,
          'subgroup', n.subgroup,
          'native_dimension', n.native_dimension,
          'native_dimension_value', n.native_dimension_value,
          'industry_slug', n.industry_slug,
          'industry_name_no', n.industry_name_no,
          'region_code', n.region_code,
          'region_label', n.region_label,
          'sample_base', n.sample_base,
          'confidence', n.confidence,
          'metadata', n.metadata
        )
        order by
          n.relevance_order,
          n.type_order,
          n.signal_rank,
          n.signal_value desc nulls last
      )
      from (
        select
          ranked.*,
          case
            when ranked.industry_slug in (
              select oi.industry_slug
              from public.occupation_industries oi
              where oi.occupation_uri = occupation.uri
            ) then 1
            when filter_region_code is not null
              and length(trim(filter_region_code)) > 0
              and ranked.region_code = filter_region_code then 2
            when ranked.industry_slug is null and ranked.region_code is null then 3
            else 4
          end as relevance_order,
          case ranked.signal_type
            when 'nho_unmet_need' then 1
            when 'nho_competence_field_need' then 2
            when 'nho_recruitment_skill_weight' then 3
            when 'nho_education_level_need' then 4
            else 9
          end as type_order
        from public.v_nho_compass_signals_ranked ranked
        where (
          ranked.industry_slug is null
          or ranked.industry_slug in (
            select oi.industry_slug
            from public.occupation_industries oi
            where oi.occupation_uri = occupation.uri
          )
        )
        and ranked.year = (
          select max(year)
          from public.nho_kb_sources
        )
        and (
          filter_region_code is null
          or length(trim(filter_region_code)) = 0
          or ranked.region_code is null
          or ranked.region_code = filter_region_code
        )
        and ranked.signal_rank <= 5
        order by
          case
            when ranked.industry_slug in (
              select oi.industry_slug
              from public.occupation_industries oi
              where oi.occupation_uri = occupation.uri
            ) then 1
            when filter_region_code is not null
              and length(trim(filter_region_code)) > 0
              and ranked.region_code = filter_region_code then 2
            when ranked.industry_slug is null and ranked.region_code is null then 3
            else 4
          end,
          case ranked.signal_type
            when 'nho_unmet_need' then 1
            when 'nho_competence_field_need' then 2
            when 'nho_recruitment_skill_weight' then 3
            when 'nho_education_level_need' then 4
            else 9
          end,
          ranked.signal_rank,
          ranked.signal_value desc nulls last
        limit 20
      ) n
    ), '[]'::jsonb)
  );
end;
$$;

grant select on public.nho_kb_sources to authenticated;
grant select on public.nho_kb_observations to authenticated;
grant select on public.nho_kb_subgroup_mappings to anon, authenticated;
grant select on public.v_nho_kb_observations_mapped to authenticated;
grant select on public.v_nho_unmet_need_signals to anon, authenticated;
grant select on public.v_nho_competence_field_signals to anon, authenticated;
grant select on public.v_nho_education_level_signals to anon, authenticated;
grant select on public.v_nho_skill_weight_signals to anon, authenticated;
grant select on public.v_nho_compass_signals to anon, authenticated;
grant select on public.v_nho_compass_signals_ranked to anon, authenticated;
grant select on public.v_nho_compass_signal_year_trends to anon, authenticated;
grant execute on function public.get_public_career_compass(text, text, text) to anon, authenticated;

with nho_import_state as (
  select
    (select count(*) from public.nho_kb_sources) as source_count,
    (select max(year) from public.nho_kb_sources) as latest_year,
    (
      select coalesce(jsonb_agg(year order by year), '[]'::jsonb)
      from (
        select distinct year
        from public.nho_kb_sources
      ) years
    ) as available_years
)
update public.external_data_sources
set
  version = coalesce(nho_import_state.latest_year::text, version, 'annual'),
  metadata = metadata || jsonb_build_object(
    'status',
      case
        when nho_import_state.source_count > 0 then 'imported'
        else coalesce(metadata->>'status', 'schema_ready_waiting_for_source_file')
      end,
    'latest_year', nho_import_state.latest_year,
    'available_years', nho_import_state.available_years,
    'raw_tables', jsonb_build_array('nho_kb_sources', 'nho_kb_observations'),
    'curated_views', jsonb_build_array(
      'v_nho_unmet_need_signals',
      'v_nho_competence_field_signals',
      'v_nho_education_level_signals',
      'v_nho_skill_weight_signals',
      'v_nho_compass_signals_ranked',
      'v_nho_compass_signal_year_trends'
    ),
    'historical_policy', 'Import new annual packages without reset. Use replace-year for corrected annual reimports so older years remain available.',
    'interpretation_warning', 'NHO data are aggregated figure data. Do not freely cross dimensions unless the published source file contains that cross-tab.'
  )
from nho_import_state
where source_key = 'nho_kompetansebarometeret';
