-- Speed up get_public_salary_profile for SSB salary tables 11420/11421.
-- The RPC filters these imported SSB observations through JSONB dimension fields.
-- Targeted expression indexes keep the public RPC under PostgREST statement
-- timeout for common industry profiles such as helse_omsorg and bygg_anlegg.

create index if not exists ssb_observations_11420_salary_profile_idx
on public.ssb_observations (
  period_year,
  (dimension_codes->>'NACE2007'),
  (dimension_codes->>'Sektor'),
  (dimension_codes->>'Kjonn'),
  (dimension_codes->>'ArbeidsTid'),
  (dimension_codes->>'MaaleMetode'),
  (dimension_codes->>'UtdanNivaa')
)
where table_id = '11420'
  and metric_code = 'Manedslonn';

create index if not exists ssb_observations_11421_salary_profile_idx
on public.ssb_observations (
  period_year,
  (dimension_codes->>'NACE2007'),
  (dimension_codes->>'Sektor'),
  (dimension_codes->>'Kjonn'),
  (dimension_codes->>'ArbeidsTid'),
  (dimension_codes->>'MaaleMetode'),
  (dimension_codes->>'Alder')
)
where table_id = '11421'
  and metric_code = 'Manedslonn';

create index if not exists industry_ssb_mappings_salary_profile_idx
on public.industry_ssb_mappings (
  industry_slug,
  ssb_dimension,
  mapping_type,
  ssb_table_id,
  confidence desc,
  ssb_code
)
where ssb_dimension = 'NACE2007'
  and mapping_type = 'nace2007'
  and ssb_table_id in ('11420', '11421', '12850');
