create table if not exists public.external_data_sources (
  source_key text primary key,
  provider text not null,
  title text not null,
  source_url text,
  version text,
  license text,
  imported_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

drop trigger if exists set_external_data_sources_updated_at on public.external_data_sources;
create trigger set_external_data_sources_updated_at
before update on public.external_data_sources
for each row execute function public.set_updated_at();

create table if not exists public.ssb_table_metadata (
  table_id text primary key,
  title text not null,
  source text not null default 'Statistisk sentralbyrå',
  source_url text,
  latest_period text,
  metadata jsonb not null default '{}'::jsonb,
  imported_at timestamptz not null default now()
);

create table if not exists public.ssb_observations (
  id bigserial primary key,
  table_id text not null references public.ssb_table_metadata(table_id) on delete cascade,
  source_file text not null,
  period text,
  period_year integer generated always as (
    case
      when period ~ '^[0-9]{4}$' then period::integer
      else null
    end
  ) stored,
  metric_code text,
  metric_label text,
  value numeric,
  unit text,
  dimension_codes jsonb not null,
  dimension_labels jsonb not null,
  dimension_key text not null,
  raw_dimension jsonb not null default '{}'::jsonb,
  imported_at timestamptz not null default now(),
  unique (table_id, source_file, dimension_key)
);

create index if not exists ssb_observations_table_period_idx
  on public.ssb_observations(table_id, period_year desc);
create index if not exists ssb_observations_metric_idx
  on public.ssb_observations(table_id, metric_code);
create index if not exists ssb_observations_dimensions_gin_idx
  on public.ssb_observations using gin (dimension_codes);

create table if not exists public.industry_ssb_mappings (
  id bigserial primary key,
  industry_slug text not null references public.industries(slug) on delete cascade,
  ssb_table_id text not null,
  ssb_dimension text not null check (ssb_dimension in ('NACE2007', 'Fagfelt')),
  ssb_code text not null,
  ssb_label text not null,
  mapping_type text not null check (mapping_type in ('nace2007', 'fagfelt')),
  confidence numeric(5,4) not null default 0.6500 check (confidence >= 0 and confidence <= 1),
  notes text,
  created_at timestamptz not null default now(),
  unique (industry_slug, ssb_table_id, ssb_dimension, ssb_code, mapping_type)
);

create index if not exists industry_ssb_mappings_industry_idx
  on public.industry_ssb_mappings(industry_slug);
create index if not exists industry_ssb_mappings_ssb_idx
  on public.industry_ssb_mappings(ssb_table_id, ssb_dimension, ssb_code);

create table if not exists public.nho_competence_signals (
  id bigserial primary key,
  source_key text references public.external_data_sources(source_key) on delete set null,
  industry_slug text references public.industries(slug) on delete set null,
  styrk_code text references public.styrk08(code) on delete set null,
  styrk_prefix text,
  region_code text,
  region_label text,
  period text,
  signal_type text not null,
  signal_label text not null,
  signal_value numeric,
  signal_rank integer,
  confidence numeric(5,4) not null default 0.7000 check (confidence >= 0 and confidence <= 1),
  metadata jsonb not null default '{}'::jsonb,
  imported_at timestamptz not null default now()
);

create index if not exists nho_competence_signals_industry_idx
  on public.nho_competence_signals(industry_slug);
create index if not exists nho_competence_signals_styrk_idx
  on public.nho_competence_signals(styrk_code, styrk_prefix);
create index if not exists nho_competence_signals_region_idx
  on public.nho_competence_signals(region_code);

insert into public.external_data_sources (
  source_key, provider, title, source_url, version, license, metadata
)
values
  (
    'ssb_labor_market_tables',
    'SSB',
    'SSB labour-market tables for public career compass',
    'https://www.ssb.no/',
    '2026-05 local export',
    'Norwegian Licence for Open Government Data (NLOD)',
    jsonb_build_object('tables', jsonb_build_array('08417', '09793', '11615', '12850'))
  ),
  (
    'nho_kompetansebarometeret',
    'NHO',
    'NHO Kompetansebarometeret competence-demand signals',
    'https://www.nho.no/tema/kompetanse-og-utdanning/kompetansebarometer/',
    null,
    null,
    jsonb_build_object('status', 'schema_ready_waiting_for_source_file')
  )
on conflict (source_key) do update set
  provider = excluded.provider,
  title = excluded.title,
  source_url = excluded.source_url,
  version = excluded.version,
  license = excluded.license,
  metadata = excluded.metadata;

insert into public.industry_ssb_mappings (
  industry_slug, ssb_table_id, ssb_dimension, ssb_code, ssb_label,
  mapping_type, confidence, notes
)
values
  -- Regional field-of-study proxy from SSB 11615.
  ('helse_omsorg', '11615', 'Fagfelt', '6', 'Helse-, sosial- og idrettsfag', 'fagfelt', 0.8000, 'Regional proxy for health and care occupations.'),
  ('utdanning', '11615', 'Fagfelt', '2', 'Lærerutdanninger og utdanninger i pedagogikk', 'fagfelt', 0.8000, 'Regional proxy for teaching and education occupations.'),
  ('okonomi_administrasjon', '11615', 'Fagfelt', '4', 'Økonomiske og administrative fag', 'fagfelt', 0.7000, 'Regional proxy for business, finance and administration.'),
  ('it_teknologi', '11615', 'Fagfelt', '5', 'Naturvitenskapelige fag, håndverksfag og tekniske fag', 'fagfelt', 0.6500, 'Broad technical field proxy; includes IT, engineering and craft education.'),
  ('bygg_anlegg', '11615', 'Fagfelt', '5', 'Naturvitenskapelige fag, håndverksfag og tekniske fag', 'fagfelt', 0.6500, 'Broad technical field proxy for construction.'),
  ('industri_produksjon', '11615', 'Fagfelt', '5', 'Naturvitenskapelige fag, håndverksfag og tekniske fag', 'fagfelt', 0.6500, 'Broad technical field proxy for industry and production.'),
  ('landbruk_fiskeri_havbruk', '11615', 'Fagfelt', '7', 'Primærnæringsfag', 'fagfelt', 0.7800, 'Regional proxy for primary-industry competence.'),
  ('transport_logistikk', '11615', 'Fagfelt', '8', 'Samferdsels- og sikkerhetsfag og andre servicefag', 'fagfelt', 0.6200, 'Broad service/transport field proxy.'),
  ('reiseliv_servering', '11615', 'Fagfelt', '8', 'Samferdsels- og sikkerhetsfag og andre servicefag', 'fagfelt', 0.5800, 'Broad service field proxy.'),
  ('salg_kundeservice', '11615', 'Fagfelt', '4', 'Økonomiske og administrative fag', 'fagfelt', 0.5500, 'Sales/customer roles often map to business education; weak public proxy.'),
  ('offentlig_forvaltning', '11615', 'Fagfelt', '3', 'Samfunnsfag og juridiske fag', 'fagfelt', 0.6000, 'Public administration proxy using social science/legal education.'),
  ('kultur_media', '11615', 'Fagfelt', '1', 'Humanistiske og estetiske fag', 'fagfelt', 0.7000, 'Regional proxy for culture and media competence.'),

  -- National industry proxy from SSB 12850.
  ('landbruk_fiskeri_havbruk', '12850', 'NACE2007', '01-03', 'Jordbruk, skogbruk og fiske', 'nace2007', 0.9000, 'Direct NACE industry group.'),
  ('industri_produksjon', '12850', 'NACE2007', '10-33', 'Industri', 'nace2007', 0.9000, 'Direct NACE industry group.'),
  ('industri_produksjon', '12850', 'NACE2007', '35-39', 'Elektrisitet, vann og renovasjon', 'nace2007', 0.6200, 'Adjacent production/technical industry.'),
  ('bygg_anlegg', '12850', 'NACE2007', '41-43', 'Bygge- og anleggsvirksomhet', 'nace2007', 0.9000, 'Direct NACE industry group.'),
  ('salg_kundeservice', '12850', 'NACE2007', '45-47', 'Varehandel, reparasjon av motorvogner', 'nace2007', 0.8500, 'Retail and sales-heavy industry group.'),
  ('transport_logistikk', '12850', 'NACE2007', '49-53', 'Transport og lagring', 'nace2007', 0.9000, 'Direct NACE industry group.'),
  ('reiseliv_servering', '12850', 'NACE2007', '55-56', 'Overnattings- og serveringsvirksomhet', 'nace2007', 0.9000, 'Direct NACE industry group.'),
  ('it_teknologi', '12850', 'NACE2007', '58-63', 'Informasjon og kommunikasjon', 'nace2007', 0.8500, 'Information and communication proxy for IT.'),
  ('okonomi_administrasjon', '12850', 'NACE2007', '64-66', 'Finansiering og forsikring', 'nace2007', 0.7000, 'Finance-heavy business proxy.'),
  ('okonomi_administrasjon', '12850', 'NACE2007', '68-75', 'Teknisk tjenesteyting, eiendomsdrift', 'nace2007', 0.6000, 'Consulting/business services proxy.'),
  ('okonomi_administrasjon', '12850', 'NACE2007', '77-82', 'Forretningsmessig tjenesteyting', 'nace2007', 0.6500, 'Business services proxy.'),
  ('offentlig_forvaltning', '12850', 'NACE2007', '84', 'Offentlig administrasjon og forsvar, og trygdeordninger underlagt offentlig forvaltning', 'nace2007', 0.8500, 'Public administration NACE group.'),
  ('utdanning', '12850', 'NACE2007', '85', 'Undervisning', 'nace2007', 0.9000, 'Direct education NACE group.'),
  ('helse_omsorg', '12850', 'NACE2007', '86-88', 'Helse- og sosialtjenester', 'nace2007', 0.9000, 'Direct health and social services NACE group.'),
  ('kultur_media', '12850', 'NACE2007', '90-99', 'Personlig tjenesteyting', 'nace2007', 0.5200, 'Weak proxy; includes parts of culture, arts and personal services.')
on conflict (industry_slug, ssb_table_id, ssb_dimension, ssb_code, mapping_type) do update set
  ssb_label = excluded.ssb_label,
  confidence = excluded.confidence,
  notes = excluded.notes;

create or replace view public.v_ssb_latest_periods as
with latest as (
  select
    table_id,
    max(period_year) as latest_period_year
  from public.ssb_observations
  where period_year is not null
  group by table_id
)
select
  l.table_id,
  l.latest_period_year,
  max(o.period) as latest_period
from latest l
join public.ssb_observations o
  on o.table_id = l.table_id
 and o.period_year = l.latest_period_year
group by l.table_id, l.latest_period_year;

create or replace view public.v_ssb_occupation_group_signals as
with base as (
  select
    o.dimension_codes->>'Yrke' as occupation_group_code,
    o.dimension_labels->>'Yrke' as occupation_group_label,
    o.dimension_codes->>'Alder' as age_code,
    o.dimension_labels->>'Alder' as age_label,
    o.period_year,
    o.value
  from public.ssb_observations o
  where o.table_id = '09793'
    and o.metric_code = 'Sysselsatte'
    and o.dimension_codes @> '{"Kjonn": "0"}'::jsonb
    and (o.dimension_codes->>'Yrke') ~ '^[0-9][0-9]$'
    and o.period_year is not null
    and o.value is not null
),
with_previous as (
  select
    b.*,
    lag(b.value) over (
      partition by b.occupation_group_code, b.age_code
      order by b.period_year
    ) as previous_value,
    lag(b.period_year) over (
      partition by b.occupation_group_code, b.age_code
      order by b.period_year
    ) as previous_period_year,
    row_number() over (
      partition by b.occupation_group_code, b.age_code
      order by b.period_year desc
    ) as recency_rank
  from base b
),
latest as (
  select *
  from with_previous
  where recency_rank = 1
),
scored as (
  select
    l.*,
    case
      when l.previous_value is null or l.previous_value = 0 then null
      else ((l.value - l.previous_value) / l.previous_value) * 100
    end as percent_change,
    max(l.value) over () as max_current_value
  from latest l
)
select
  occupation_group_code,
  occupation_group_label,
  age_code,
  age_label,
  period_year as latest_period_year,
  value as employed_latest_thousands,
  previous_period_year,
  previous_value as employed_previous_thousands,
  round((value - coalesce(previous_value, value))::numeric, 2) as absolute_change_thousands,
  round(percent_change::numeric, 2) as percent_change,
  round(
    least(
      100,
      greatest(
        0,
        (
          (coalesce(value / nullif(max_current_value, 0), 0) * 55)
          + (least(1, greatest(0, (coalesce(percent_change, 0) + 8) / 16)) * 45)
        )
      )
    )::numeric,
    2
  ) as market_signal_score,
  case
    when (
      (coalesce(value / nullif(max_current_value, 0), 0) * 55)
      + (least(1, greatest(0, (coalesce(percent_change, 0) + 8) / 16)) * 45)
    ) >= 70 then 'high'
    when (
      (coalesce(value / nullif(max_current_value, 0), 0) * 55)
      + (least(1, greatest(0, (coalesce(percent_change, 0) + 8) / 16)) * 45)
    ) >= 40 then 'medium'
    else 'low'
  end as market_signal_level
from scored;

create or replace view public.v_occupation_market_signals as
with mapped_groups as (
  select distinct
    m.occupation_uri,
    left(m.styrk_code, 2) as occupation_group_code,
    m.confidence as mapping_confidence
  from public.esco_styrk_mappings m
  where m.styrk_code ~ '^[0-9]{4}$'
),
joined as (
  select
    mg.occupation_uri,
    g.occupation_group_code,
    g.occupation_group_label,
    g.age_code,
    g.age_label,
    g.latest_period_year,
    g.employed_latest_thousands,
    g.previous_period_year,
    g.employed_previous_thousands,
    g.absolute_change_thousands,
    g.percent_change,
    g.market_signal_score,
    g.market_signal_level,
    mg.mapping_confidence
  from mapped_groups mg
  join public.v_ssb_occupation_group_signals g
    on g.occupation_group_code = mg.occupation_group_code
)
select
  j.occupation_uri,
  e.title_no,
  e.title_en,
  round(avg(j.market_signal_score)::numeric, 2) as market_signal_score,
  case
    when avg(j.market_signal_score) >= 70 then 'high'
    when avg(j.market_signal_score) >= 40 then 'medium'
    else 'low'
  end as market_signal_level,
  max(j.latest_period_year) as latest_period_year,
  round(sum(j.employed_latest_thousands)::numeric, 2) as employed_latest_thousands,
  round(sum(coalesce(j.employed_previous_thousands, 0))::numeric, 2) as employed_previous_thousands,
  round(sum(j.absolute_change_thousands)::numeric, 2) as absolute_change_thousands,
  round(avg(j.percent_change)::numeric, 2) as percent_change,
  jsonb_agg(
    jsonb_build_object(
      'occupation_group_code', j.occupation_group_code,
      'occupation_group_label', j.occupation_group_label,
      'age_code', j.age_code,
      'age_label', j.age_label,
      'latest_period_year', j.latest_period_year,
      'employed_latest_thousands', j.employed_latest_thousands,
      'previous_period_year', j.previous_period_year,
      'employed_previous_thousands', j.employed_previous_thousands,
      'percent_change', j.percent_change,
      'market_signal_score', j.market_signal_score,
      'market_signal_level', j.market_signal_level,
      'mapping_confidence', j.mapping_confidence
    )
    order by j.market_signal_score desc
  ) as source_groups
from joined j
join public.esco_entities e on e.uri = j.occupation_uri
where e.entity_type = 'occupation'
group by j.occupation_uri, e.title_no, e.title_en;

create or replace view public.v_industry_national_signals as
with base as (
  select
    o.dimension_codes->>'NACE2007' as nace_code,
    o.dimension_labels->>'NACE2007' as nace_label,
    o.period_year,
    sum(o.value) as employed_value
  from public.ssb_observations o
  where o.table_id = '12850'
    and o.metric_code = 'SysselsatteArbSted'
    and o.dimension_codes @> '{"Region": "0", "UtdNivaa": "0", "Fagfelt": "00"}'::jsonb
    and (o.dimension_codes->>'NACE2007') <> '00-99'
    and o.period_year is not null
    and o.value is not null
  group by o.dimension_codes->>'NACE2007', o.dimension_labels->>'NACE2007', o.period_year
),
with_previous as (
  select
    b.*,
    lag(b.employed_value) over (partition by b.nace_code order by b.period_year) as previous_value,
    lag(b.period_year) over (partition by b.nace_code order by b.period_year) as previous_period_year,
    row_number() over (partition by b.nace_code order by b.period_year desc) as recency_rank
  from base b
),
latest as (
  select *
  from with_previous
  where recency_rank = 1
),
mapped as (
  select
    m.industry_slug,
    i.name_no as industry_name_no,
    m.confidence,
    l.*
  from latest l
  join public.industry_ssb_mappings m
    on m.mapping_type = 'nace2007'
   and m.ssb_table_id = '12850'
   and m.ssb_code = l.nace_code
  join public.industries i on i.slug = m.industry_slug
)
select
  industry_slug,
  industry_name_no,
  max(period_year) as latest_period_year,
  round(sum(employed_value)::numeric, 2) as employed_latest,
  max(previous_period_year) as previous_period_year,
  round(sum(coalesce(previous_value, 0))::numeric, 2) as employed_previous,
  round(sum(employed_value - coalesce(previous_value, employed_value))::numeric, 2) as absolute_change,
  round(
    case
      when sum(coalesce(previous_value, 0)) = 0 then null
      else ((sum(employed_value) - sum(previous_value)) / sum(previous_value)) * 100
    end::numeric,
    2
  ) as percent_change,
  round(avg(confidence)::numeric, 4) as mapping_confidence,
  jsonb_agg(
    jsonb_build_object(
      'nace_code', nace_code,
      'nace_label', nace_label,
      'latest_period_year', period_year,
      'employed_latest', employed_value,
      'previous_period_year', previous_period_year,
      'employed_previous', previous_value,
      'mapping_confidence', confidence
    )
    order by confidence desc, employed_value desc
  ) as source_groups
from mapped
group by industry_slug, industry_name_no;

create or replace view public.v_occupation_regional_signals as
with mapped_fields as (
  select distinct
    oi.occupation_uri,
    oi.industry_slug,
    ism.ssb_code as field_code,
    ism.ssb_label as field_label,
    ism.confidence as mapping_confidence
  from public.occupation_industries oi
  join public.industry_ssb_mappings ism
    on ism.industry_slug = oi.industry_slug
   and ism.mapping_type = 'fagfelt'
   and ism.ssb_table_id = '11615'
),
regional_base as (
  select
    o.dimension_codes->>'Region' as region_code,
    o.dimension_labels->>'Region' as region_label,
    o.dimension_codes->>'Fagfelt' as field_code,
    o.dimension_labels->>'Fagfelt' as field_label,
    o.period_year,
    sum(o.value) as employed_value
  from public.ssb_observations o
  where o.table_id = '11615'
    and o.metric_code = 'SysselsatteArbSted'
    and o.dimension_codes->>'Region' <> '0'
    and o.period_year is not null
    and o.value is not null
  group by
    o.dimension_codes->>'Region',
    o.dimension_labels->>'Region',
    o.dimension_codes->>'Fagfelt',
    o.dimension_labels->>'Fagfelt',
    o.period_year
),
regional_previous as (
  select
    rb.*,
    lag(rb.employed_value) over (
      partition by rb.region_code, rb.field_code
      order by rb.period_year
    ) as previous_value,
    lag(rb.period_year) over (
      partition by rb.region_code, rb.field_code
      order by rb.period_year
    ) as previous_period_year,
    row_number() over (
      partition by rb.region_code, rb.field_code
      order by rb.period_year desc
    ) as recency_rank
  from regional_base rb
),
latest as (
  select *
  from regional_previous
  where recency_rank = 1
),
joined as (
  select
    mf.occupation_uri,
    mf.industry_slug,
    mf.mapping_confidence,
    l.region_code,
    l.region_label,
    l.field_code,
    l.field_label,
    l.period_year,
    l.employed_value,
    l.previous_period_year,
    l.previous_value
  from mapped_fields mf
  join latest l on l.field_code = mf.field_code
),
aggregated as (
  select
    occupation_uri,
    region_code,
    region_label,
    max(period_year) as latest_period_year,
    sum(employed_value) as employed_latest,
    max(previous_period_year) as previous_period_year,
    sum(coalesce(previous_value, 0)) as employed_previous,
    avg(mapping_confidence) as mapping_confidence,
    jsonb_agg(
      jsonb_build_object(
        'industry_slug', industry_slug,
        'field_code', field_code,
        'field_label', field_label,
        'employed_latest', employed_value,
        'previous_value', previous_value,
        'mapping_confidence', mapping_confidence
      )
      order by employed_value desc
    ) as source_fields
  from joined
  group by occupation_uri, region_code, region_label
)
select
  occupation_uri,
  region_code,
  region_label,
  latest_period_year,
  round(employed_latest::numeric, 2) as employed_latest,
  previous_period_year,
  round(employed_previous::numeric, 2) as employed_previous,
  round((employed_latest - coalesce(employed_previous, employed_latest))::numeric, 2) as absolute_change,
  round(
    case
      when employed_previous is null or employed_previous = 0 then null
      else ((employed_latest - employed_previous) / employed_previous) * 100
    end::numeric,
    2
  ) as percent_change,
  round((employed_latest / nullif(max(employed_latest) over (partition by occupation_uri), 0) * 100)::numeric, 2) as relevance_score,
  round(mapping_confidence::numeric, 4) as mapping_confidence,
  source_fields
from aggregated;

create or replace function public.get_related_occupations(
  input_occupation_uri text,
  result_limit int default 6
)
returns table (
  occupation_uri text,
  title_no text,
  title_en text,
  overlap_count bigint,
  overlap_score numeric,
  industry_slugs text[],
  industry_names text[],
  shared_skills jsonb
)
language sql
stable
as $$
  with base_skills as (
    select skill_uri, relation_type
    from public.esco_occupation_skills
    where occupation_uri = input_occupation_uri
  ),
  base_count as (
    select count(*)::numeric as total_count
    from base_skills
  ),
  overlap_rows as (
    select
      os.occupation_uri,
      count(*) as overlap_count,
      sum(
        case
          when os.relation_type = 'essential' and bs.relation_type = 'essential' then 1.50
          when os.relation_type = 'essential' or bs.relation_type = 'essential' then 1.15
          else 1.00
        end
      ) as weighted_overlap
    from public.esco_occupation_skills os
    join base_skills bs on bs.skill_uri = os.skill_uri
    where os.occupation_uri <> input_occupation_uri
    group by os.occupation_uri
  ),
  ranked as (
    select
      o.occupation_uri,
      e.title_no,
      e.title_en,
      o.overlap_count,
      round(((o.weighted_overlap / nullif(bc.total_count, 0)) * 100)::numeric, 2) as overlap_score
    from overlap_rows o
    cross join base_count bc
    join public.esco_entities e on e.uri = o.occupation_uri
    where e.entity_type = 'occupation'
    order by o.weighted_overlap desc, o.overlap_count desc, e.title_no asc nulls last
    limit least(result_limit, 20)
  )
  select
    r.occupation_uri,
    r.title_no,
    r.title_en,
    r.overlap_count,
    r.overlap_score,
    coalesce(i.industry_slugs, '{}'::text[]) as industry_slugs,
    coalesce(i.industry_names, '{}'::text[]) as industry_names,
    coalesce(s.shared_skills, '[]'::jsonb) as shared_skills
  from ranked r
  left join lateral (
    select
      array_agg(distinct oi.industry_slug order by oi.industry_slug) as industry_slugs,
      array_agg(distinct ind.name_no order by ind.name_no) as industry_names
    from public.occupation_industries oi
    join public.industries ind on ind.slug = oi.industry_slug
    where oi.occupation_uri = r.occupation_uri
  ) i on true
  left join lateral (
    select jsonb_agg(
      jsonb_build_object(
        'skill_uri', x.skill_uri,
        'title_no', x.title_no,
        'relation_type', x.relation_type
      )
      order by x.relation_type, x.title_no
    ) as shared_skills
    from (
      select
        sk.uri as skill_uri,
        sk.title_no,
        os.relation_type
      from public.esco_occupation_skills os
      join base_skills bs on bs.skill_uri = os.skill_uri
      join public.esco_entities sk on sk.uri = os.skill_uri
      where os.occupation_uri = r.occupation_uri
      order by
        case when os.relation_type = 'essential' then 0 else 1 end,
        sk.title_no asc nulls last
      limit 8
    ) x
  ) s on true;
$$;

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
          'signal_rank', n.signal_rank,
          'period', n.period,
          'industry_slug', n.industry_slug,
          'region_code', n.region_code,
          'confidence', n.confidence
        )
        order by n.signal_rank nulls last, n.signal_value desc nulls last
      )
      from public.nho_competence_signals n
      where (
        n.industry_slug is null
        or n.industry_slug in (
          select oi.industry_slug
          from public.occupation_industries oi
          where oi.occupation_uri = occupation.uri
        )
      )
      and (
        n.styrk_code is null
        or n.styrk_code in (
          select m.styrk_code
          from public.esco_styrk_mappings m
          where m.occupation_uri = occupation.uri
        )
      )
      limit 10
    ), '[]'::jsonb)
  );
end;
$$;

grant select on public.external_data_sources to anon, authenticated;
grant select on public.ssb_table_metadata to anon, authenticated;
grant select on public.ssb_observations to authenticated;
grant select on public.industry_ssb_mappings to anon, authenticated;
grant select on public.nho_competence_signals to anon, authenticated;
grant select on public.v_ssb_latest_periods to anon, authenticated;
grant select on public.v_ssb_occupation_group_signals to anon, authenticated;
grant select on public.v_occupation_market_signals to anon, authenticated;
grant select on public.v_industry_national_signals to anon, authenticated;
grant select on public.v_occupation_regional_signals to anon, authenticated;
grant execute on function public.get_related_occupations(text, int) to anon, authenticated;
grant execute on function public.get_public_career_compass(text, text, text) to anon, authenticated;
