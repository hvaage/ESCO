create table if not exists public.industries (
  slug text primary key,
  name_no text not null,
  description_no text,
  sort_order integer not null default 100,
  created_at timestamptz not null default now()
);

create table if not exists public.occupation_industry_rules (
  id bigserial primary key,
  industry_slug text not null references public.industries(slug) on delete cascade,
  rule_type text not null check (rule_type in ('styrk_prefix', 'title_keyword')),
  pattern text not null,
  pattern_label text,
  confidence numeric(5,4) not null default 0.6500 check (confidence >= 0 and confidence <= 1),
  weight numeric(8,4) not null default 1,
  notes text,
  created_at timestamptz not null default now(),
  unique (industry_slug, rule_type, pattern)
);

create table if not exists public.occupation_industries (
  occupation_uri text not null references public.esco_entities(uri) on delete cascade,
  industry_slug text not null references public.industries(slug) on delete cascade,
  source text not null,
  confidence numeric(5,4) not null check (confidence >= 0 and confidence <= 1),
  weight numeric(8,4) not null default 1,
  evidence jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (occupation_uri, industry_slug)
);

create index if not exists occupation_industries_industry_idx
  on public.occupation_industries(industry_slug);
create index if not exists occupation_industries_confidence_idx
  on public.occupation_industries(confidence desc, weight desc);
create index if not exists occupation_industry_rules_industry_idx
  on public.occupation_industry_rules(industry_slug);

insert into public.industries (slug, name_no, description_no, sort_order)
values
  ('helse_omsorg', 'Helse og omsorg', 'Helse, pleie, sosialt arbeid, terapi og omsorgsroller.', 10),
  ('it_teknologi', 'IT og teknologi', 'IKT, programvare, data, sky, sikkerhet og teknisk digital drift.', 20),
  ('bygg_anlegg', 'Bygg og anlegg', 'Bygg, anlegg, arkitektur, planlegging og installasjonsfag.', 30),
  ('utdanning', 'Utdanning', 'Undervisning, opplaering, barnehage, skole og akademia.', 40),
  ('okonomi_administrasjon', 'Økonomi og administrasjon', 'Økonomi, HR, ledelse, administrasjon, kontor og rådgivning.', 50),
  ('salg_kundeservice', 'Salg og kundeservice', 'Salg, varehandel, markedsforing, service og kundekontakt.', 60),
  ('transport_logistikk', 'Transport og logistikk', 'Transport, logistikk, lager, spedisjon, sjofart og luftfart.', 70),
  ('industri_produksjon', 'Industri og produksjon', 'Produksjon, prosess, maskin, metall, kjemi og tekniske operatorroller.', 80),
  ('reiseliv_servering', 'Reiseliv og servering', 'Hotell, restaurant, servering, reise og opplevelser.', 90),
  ('offentlig_forvaltning', 'Offentlig sektor og forvaltning', 'Forvaltning, politikk, forsvar, sikkerhet, jus og offentlige tjenester.', 100),
  ('kultur_media', 'Kultur og media', 'Design, media, kunst, kultur, innhold og kreative yrker.', 110),
  ('landbruk_fiskeri_havbruk', 'Landbruk, fiskeri og havbruk', 'Jordbruk, skogbruk, fiske, fangst, dyrehold og havbruk.', 120)
on conflict (slug) do update set
  name_no = excluded.name_no,
  description_no = excluded.description_no,
  sort_order = excluded.sort_order;

insert into public.occupation_industry_rules (
  industry_slug, rule_type, pattern, pattern_label, confidence, weight, notes
)
values
  -- Helse og omsorg
  ('helse_omsorg', 'styrk_prefix', '1342', 'Ledere innen helsetjenester', 0.8000, 1.20, 'STYRK health management'),
  ('helse_omsorg', 'styrk_prefix', '22', 'Medisinske yrker', 0.8500, 1.20, 'STYRK health professionals'),
  ('helse_omsorg', 'styrk_prefix', '32', 'Helseyrker med hoyskolekompetanse', 0.8500, 1.15, 'STYRK health associate professionals'),
  ('helse_omsorg', 'styrk_prefix', '3412', 'Miljoarbeidere innen sosiale fagfelt', 0.7500, 1.00, 'Social care roles'),
  ('helse_omsorg', 'styrk_prefix', '53', 'Omsorgsarbeidere', 0.8000, 1.05, 'Care workers'),
  ('helse_omsorg', 'title_keyword', 'sykepleier', 'Sykepleier', 0.8000, 1.20, 'Norwegian health title keyword'),
  ('helse_omsorg', 'title_keyword', 'lege', 'Lege', 0.7600, 1.10, 'Norwegian health title keyword'),
  ('helse_omsorg', 'title_keyword', 'helse', 'Helse', 0.6500, 0.80, 'Broad health title keyword'),

  -- IT og teknologi
  ('it_teknologi', 'styrk_prefix', '1330', 'Ledere av IKT-enheter', 0.8500, 1.20, 'ICT managers'),
  ('it_teknologi', 'styrk_prefix', '25', 'IKT-radgivere og programvareutviklere', 0.9000, 1.30, 'ICT professionals'),
  ('it_teknologi', 'styrk_prefix', '35', 'Informasjons- og kommunikasjonsteknikere', 0.8500, 1.15, 'ICT technicians'),
  ('it_teknologi', 'title_keyword', 'programvare', 'Programvare', 0.8000, 1.15, 'Software title keyword'),
  ('it_teknologi', 'title_keyword', 'utvikler', 'Utvikler', 0.7000, 0.95, 'Developer title keyword'),
  ('it_teknologi', 'title_keyword', 'data', 'Data', 0.6200, 0.70, 'Broad data title keyword'),
  ('it_teknologi', 'title_keyword', 'IKT', 'IKT', 0.7800, 1.10, 'ICT title keyword'),
  ('it_teknologi', 'title_keyword', 'sky', 'Sky', 0.7200, 0.90, 'Cloud title keyword'),

  -- Bygg og anlegg
  ('bygg_anlegg', 'styrk_prefix', '1323', 'Ledere innen bygge- og anleggsvirksomhet', 0.8500, 1.20, 'Construction managers'),
  ('bygg_anlegg', 'styrk_prefix', '2142', 'Sivilingeniorer bygg og anlegg', 0.8500, 1.15, 'Civil engineering'),
  ('bygg_anlegg', 'styrk_prefix', '2161', 'Arkitekter', 0.7600, 0.95, 'Architecture'),
  ('bygg_anlegg', 'styrk_prefix', '2164', 'Arealplanleggere', 0.7200, 0.90, 'Urban planning'),
  ('bygg_anlegg', 'styrk_prefix', '3112', 'Bygningsingeniorer', 0.8500, 1.10, 'Building technicians'),
  ('bygg_anlegg', 'styrk_prefix', '3123', 'Arbeidsleder bygg og anlegg', 0.8500, 1.10, 'Construction supervisors'),
  ('bygg_anlegg', 'styrk_prefix', '71', 'Bygningsarbeidere', 0.8200, 1.05, 'Building trades'),
  ('bygg_anlegg', 'styrk_prefix', '7411', 'Elektrikere', 0.7000, 0.85, 'Installation electricians'),
  ('bygg_anlegg', 'styrk_prefix', '9312', 'Hjelpearbeidere i anlegg', 0.7500, 0.90, 'Construction labour'),
  ('bygg_anlegg', 'title_keyword', 'bygg', 'Bygg', 0.7400, 1.00, 'Construction title keyword'),
  ('bygg_anlegg', 'title_keyword', 'anlegg', 'Anlegg', 0.7400, 1.00, 'Construction title keyword'),

  -- Utdanning
  ('utdanning', 'styrk_prefix', '1345', 'Ledere innen utdanning', 0.8500, 1.15, 'Education managers'),
  ('utdanning', 'styrk_prefix', '23', 'Undervisningsyrker', 0.9000, 1.30, 'Teaching professionals'),
  ('utdanning', 'styrk_prefix', '531', 'Barne- og skoleassistenter', 0.6800, 0.80, 'Child and school assistants'),
  ('utdanning', 'title_keyword', 'laerer', 'Laerer', 0.7800, 1.05, 'ASCII fallback for laerer titles'),
  ('utdanning', 'title_keyword', 'lærer', 'Laerer', 0.8200, 1.10, 'Norwegian teacher title keyword'),
  ('utdanning', 'title_keyword', 'undervis', 'Undervisning', 0.7200, 0.95, 'Education title keyword'),

  -- Økonomi og administrasjon
  ('okonomi_administrasjon', 'styrk_prefix', '12', 'Administrative og merkantile ledere', 0.6800, 0.85, 'Broad management/admin'),
  ('okonomi_administrasjon', 'styrk_prefix', '24', 'Økonomi, administrasjon og salg', 0.7600, 1.00, 'Business professionals'),
  ('okonomi_administrasjon', 'styrk_prefix', '33', 'Forretnings- og administrasjonsyrker', 0.7600, 1.00, 'Business associate professionals'),
  ('okonomi_administrasjon', 'styrk_prefix', '41', 'Kontormedarbeidere', 0.7600, 1.00, 'Office clerks'),
  ('okonomi_administrasjon', 'styrk_prefix', '431', 'Regnskaps- og lønnsmedarbeidere', 0.8500, 1.10, 'Accounting/payroll clerks'),
  ('okonomi_administrasjon', 'title_keyword', 'regnskap', 'Regnskap', 0.8200, 1.10, 'Accounting title keyword'),
  ('okonomi_administrasjon', 'title_keyword', 'okonomi', 'Økonomi', 0.7400, 1.00, 'ASCII economy title keyword'),
  ('okonomi_administrasjon', 'title_keyword', 'økonomi', 'Økonomi', 0.7800, 1.05, 'Norwegian economy title keyword'),
  ('okonomi_administrasjon', 'title_keyword', 'administr', 'Administrasjon', 0.7000, 0.90, 'Administration title keyword'),

  -- Salg og kundeservice
  ('salg_kundeservice', 'styrk_prefix', '1420', 'Varehandelssjefer', 0.8200, 1.10, 'Retail managers'),
  ('salg_kundeservice', 'styrk_prefix', '243', 'Salgs- og markedsforingsradgivere', 0.7600, 1.00, 'Sales and marketing professionals'),
  ('salg_kundeservice', 'styrk_prefix', '332', 'Salgs- og innkjopsagenter', 0.7600, 0.95, 'Sales and purchasing agents'),
  ('salg_kundeservice', 'styrk_prefix', '42', 'Kundeservice- og opplysningsmedarbeidere', 0.8200, 1.10, 'Customer service clerks'),
  ('salg_kundeservice', 'styrk_prefix', '52', 'Salgsmedarbeidere', 0.8500, 1.20, 'Sales workers'),
  ('salg_kundeservice', 'title_keyword', 'salg', 'Salg', 0.7600, 1.00, 'Sales title keyword'),
  ('salg_kundeservice', 'title_keyword', 'kunde', 'Kunde', 0.7200, 0.95, 'Customer title keyword'),
  ('salg_kundeservice', 'title_keyword', 'butikk', 'Butikk', 0.7600, 1.00, 'Retail title keyword'),

  -- Transport og logistikk
  ('transport_logistikk', 'styrk_prefix', '1324', 'Ledere av logistikk og transport', 0.8500, 1.20, 'Logistics/transport managers'),
  ('transport_logistikk', 'styrk_prefix', '315', 'Skips- og flyforere mv.', 0.8200, 1.10, 'Marine and aviation'),
  ('transport_logistikk', 'styrk_prefix', '432', 'Logistikk- og transportfunksjonaerer', 0.8500, 1.20, 'Logistics clerks'),
  ('transport_logistikk', 'styrk_prefix', '511', 'Flyverter, konduktorer og reiseledere', 0.7200, 0.85, 'Passenger transport and travel'),
  ('transport_logistikk', 'styrk_prefix', '83', 'Transportarbeidere og mobile maskinforere', 0.8500, 1.20, 'Drivers and mobile plant operators'),
  ('transport_logistikk', 'title_keyword', 'logistikk', 'Logistikk', 0.8200, 1.10, 'Logistics title keyword'),
  ('transport_logistikk', 'title_keyword', 'transport', 'Transport', 0.8000, 1.05, 'Transport title keyword'),
  ('transport_logistikk', 'title_keyword', 'sjåfør', 'Sjafor', 0.8200, 1.10, 'Driver title keyword'),

  -- Industri og produksjon
  ('industri_produksjon', 'styrk_prefix', '1321', 'Ledere av industriproduksjon', 0.8500, 1.20, 'Industrial production managers'),
  ('industri_produksjon', 'styrk_prefix', '2141', 'Sivilingeniorer industri og produksjon', 0.8500, 1.10, 'Industrial engineering'),
  ('industri_produksjon', 'styrk_prefix', '2144', 'Sivilingeniorer maskin og marin', 0.7200, 0.85, 'Mechanical/marine engineering'),
  ('industri_produksjon', 'styrk_prefix', '2145', 'Sivilingeniorer kjemi', 0.7600, 0.95, 'Chemical engineering'),
  ('industri_produksjon', 'styrk_prefix', '3115', 'Maskiningeniorer', 0.7600, 0.95, 'Mechanical technicians'),
  ('industri_produksjon', 'styrk_prefix', '3116', 'Kjemiingeniorer', 0.7600, 0.95, 'Chemical technicians'),
  ('industri_produksjon', 'styrk_prefix', '3122', 'Arbeidsleder industri', 0.8500, 1.10, 'Industrial supervisors'),
  ('industri_produksjon', 'styrk_prefix', '72', 'Metall- og maskinarbeidere', 0.8000, 1.00, 'Metal and machinery trades'),
  ('industri_produksjon', 'styrk_prefix', '73', 'Presisjons- og kunsthandverkere', 0.6500, 0.70, 'Manufacturing/craft production'),
  ('industri_produksjon', 'styrk_prefix', '75', 'Handverkere innen naeringsmiddel mv.', 0.7800, 0.95, 'Food/textile/craft production'),
  ('industri_produksjon', 'styrk_prefix', '81', 'Prosess- og maskinoperatorer', 0.8500, 1.20, 'Plant and machine operators'),
  ('industri_produksjon', 'styrk_prefix', '82', 'Montorer', 0.8000, 1.00, 'Assemblers'),
  ('industri_produksjon', 'title_keyword', 'produksjon', 'Produksjon', 0.7800, 1.05, 'Production title keyword'),
  ('industri_produksjon', 'title_keyword', 'operator', 'Operator', 0.7000, 0.90, 'Operator title keyword'),
  ('industri_produksjon', 'title_keyword', 'operatør', 'Operator', 0.7600, 0.95, 'Norwegian operator title keyword'),

  -- Reiseliv og servering
  ('reiseliv_servering', 'styrk_prefix', '141', 'Hotell- og restaurantsjefer', 0.8500, 1.20, 'Hospitality managers'),
  ('reiseliv_servering', 'styrk_prefix', '4224', 'Hotellresepsjonister', 0.8500, 1.10, 'Hotel reception'),
  ('reiseliv_servering', 'styrk_prefix', '51', 'Personlige tjenesteytere', 0.6500, 0.70, 'Broad services, includes hospitality'),
  ('reiseliv_servering', 'styrk_prefix', '512', 'Kokker', 0.8500, 1.10, 'Cooks'),
  ('reiseliv_servering', 'styrk_prefix', '513', 'Servitorer og bartendere', 0.8500, 1.10, 'Waiters and bartenders'),
  ('reiseliv_servering', 'title_keyword', 'hotell', 'Hotell', 0.8200, 1.05, 'Hotel title keyword'),
  ('reiseliv_servering', 'title_keyword', 'restaurant', 'Restaurant', 0.8200, 1.05, 'Restaurant title keyword'),
  ('reiseliv_servering', 'title_keyword', 'reise', 'Reise', 0.7000, 0.85, 'Travel title keyword'),

  -- Offentlig sektor og forvaltning
  ('offentlig_forvaltning', 'styrk_prefix', '0', 'Militaere yrker', 0.8000, 1.10, 'Military occupations'),
  ('offentlig_forvaltning', 'styrk_prefix', '11', 'Toppledere og politikere', 0.7200, 0.85, 'Public leadership/politics'),
  ('offentlig_forvaltning', 'styrk_prefix', '261', 'Juridiske yrker', 0.7000, 0.90, 'Legal professions'),
  ('offentlig_forvaltning', 'styrk_prefix', '2422', 'Hoyere saksbehandlere', 0.6800, 0.80, 'Case officers, often public sector'),
  ('offentlig_forvaltning', 'styrk_prefix', '335', 'Offentlige saksbehandlere og kontrollorer', 0.8500, 1.15, 'Public administration inspectors'),
  ('offentlig_forvaltning', 'styrk_prefix', '541', 'Sikkerhetsarbeidere', 0.7200, 0.85, 'Security services'),
  ('offentlig_forvaltning', 'title_keyword', 'offentlig', 'Offentlig', 0.7600, 1.00, 'Public sector title keyword'),
  ('offentlig_forvaltning', 'title_keyword', 'kommune', 'Kommune', 0.7400, 0.95, 'Municipality title keyword'),
  ('offentlig_forvaltning', 'title_keyword', 'juridisk', 'Juridisk', 0.7000, 0.90, 'Legal title keyword'),

  -- Kultur og media
  ('kultur_media', 'styrk_prefix', '2166', 'Grafiske- og multimediadesignere', 0.8500, 1.15, 'Design and multimedia'),
  ('kultur_media', 'styrk_prefix', '264', 'Forfattere, journalister og sprakarbeidere', 0.8500, 1.15, 'Writing and journalism'),
  ('kultur_media', 'styrk_prefix', '265', 'Kunstnere', 0.8500, 1.15, 'Artists'),
  ('kultur_media', 'styrk_prefix', '343', 'Yrker innen estetiske fag', 0.8000, 1.00, 'Creative associate roles'),
  ('kultur_media', 'title_keyword', 'design', 'Design', 0.7600, 0.95, 'Design title keyword'),
  ('kultur_media', 'title_keyword', 'media', 'Media', 0.7600, 0.95, 'Media title keyword'),
  ('kultur_media', 'title_keyword', 'journalist', 'Journalist', 0.8200, 1.10, 'Journalism title keyword'),
  ('kultur_media', 'title_keyword', 'kunst', 'Kunst', 0.7600, 0.95, 'Art title keyword'),

  -- Landbruk, fiskeri og havbruk
  ('landbruk_fiskeri_havbruk', 'styrk_prefix', '1311', 'Ledere innen jordbruk, skogbruk og fiske', 0.8500, 1.10, 'Agriculture/fishery managers'),
  ('landbruk_fiskeri_havbruk', 'styrk_prefix', '2132', 'Radgivere innen jordbruk, skogbruk og fiske', 0.7600, 0.95, 'Agriculture advisers'),
  ('landbruk_fiskeri_havbruk', 'styrk_prefix', '3142', 'Landbruks- og skogbruksteknikere', 0.8000, 1.00, 'Agriculture technicians'),
  ('landbruk_fiskeri_havbruk', 'styrk_prefix', '61', 'Jordbrukere', 0.9000, 1.25, 'Agriculture workers/producers'),
  ('landbruk_fiskeri_havbruk', 'styrk_prefix', '62', 'Skogbrukere, fiskere og fangstfolk', 0.9000, 1.25, 'Forestry/fishery workers'),
  ('landbruk_fiskeri_havbruk', 'styrk_prefix', '63', 'Kombinasjonsbrukere', 0.8500, 1.10, 'Subsistence agriculture/fishery'),
  ('landbruk_fiskeri_havbruk', 'styrk_prefix', '92', 'Hjelpearbeidere i jordbruk mv.', 0.8200, 1.05, 'Agriculture labourers'),
  ('landbruk_fiskeri_havbruk', 'title_keyword', 'landbruk', 'Landbruk', 0.8200, 1.10, 'Agriculture title keyword'),
  ('landbruk_fiskeri_havbruk', 'title_keyword', 'fisk', 'Fisk', 0.8000, 1.05, 'Fishery title keyword'),
  ('landbruk_fiskeri_havbruk', 'title_keyword', 'havbruk', 'Havbruk', 0.8500, 1.15, 'Aquaculture title keyword')
on conflict (industry_slug, rule_type, pattern) do update set
  pattern_label = excluded.pattern_label,
  confidence = excluded.confidence,
  weight = excluded.weight,
  notes = excluded.notes;

create or replace function public.refresh_occupation_industries()
returns void
language plpgsql
as $$
begin
  truncate table public.occupation_industries;

  insert into public.occupation_industries (
    occupation_uri, industry_slug, source, confidence, weight, evidence, updated_at
  )
  select
    matches.occupation_uri,
    matches.industry_slug,
    'seed:styrk_prefix' as source,
    least(0.9500, max(matches.adjusted_confidence))::numeric(5,4) as confidence,
    max(matches.weight)::numeric(8,4) as weight,
    jsonb_agg(matches.evidence order by matches.rule_id, matches.styrk_code) as evidence,
    now() as updated_at
  from (
    select
      m.occupation_uri,
      r.industry_slug,
      r.id as rule_id,
      m.styrk_code,
      r.weight,
      r.confidence * (0.7500 + (coalesce(m.confidence, 3)::numeric / 20.0000)) as adjusted_confidence,
      jsonb_build_object(
        'rule_id', r.id,
        'rule_type', r.rule_type,
        'pattern', r.pattern,
        'pattern_label', r.pattern_label,
        'styrk_code', m.styrk_code,
        'styrk_title', m.styrk_title,
        'mapping_relation', m.mapping_relation,
        'mapping_confidence', m.confidence
      ) as evidence
    from public.occupation_industry_rules r
    join public.v_esco_styrk_occupations m
      on m.styrk_code like r.pattern || '%'
    where r.rule_type = 'styrk_prefix'
  ) matches
  group by matches.occupation_uri, matches.industry_slug
  on conflict (occupation_uri, industry_slug) do update set
    source = excluded.source,
    confidence = greatest(public.occupation_industries.confidence, excluded.confidence),
    weight = greatest(public.occupation_industries.weight, excluded.weight),
    evidence = public.occupation_industries.evidence || excluded.evidence,
    updated_at = now();

  insert into public.occupation_industries (
    occupation_uri, industry_slug, source, confidence, weight, evidence, updated_at
  )
  select
    matches.occupation_uri,
    matches.industry_slug,
    'seed:title_keyword' as source,
    max(matches.confidence)::numeric(5,4) as confidence,
    max(matches.weight)::numeric(8,4) as weight,
    jsonb_agg(matches.evidence order by matches.rule_id, matches.alias) as evidence,
    now() as updated_at
  from (
    select distinct
      a.occupation_uri,
      r.industry_slug,
      r.id as rule_id,
      a.alias,
      r.confidence,
      r.weight,
      jsonb_build_object(
        'rule_id', r.id,
        'rule_type', r.rule_type,
        'pattern', r.pattern,
        'pattern_label', r.pattern_label,
        'matched_alias', a.alias,
        'alias_type', a.alias_type,
        'source', a.source
      ) as evidence
    from public.occupation_industry_rules r
    join public.esco_occupation_aliases a
      on lower(extensions.unaccent(a.alias)) like '%' || lower(extensions.unaccent(r.pattern)) || '%'
    where r.rule_type = 'title_keyword'
  ) matches
  group by matches.occupation_uri, matches.industry_slug
  on conflict (occupation_uri, industry_slug) do update set
    source = case
      when excluded.confidence > public.occupation_industries.confidence then excluded.source
      else public.occupation_industries.source
    end,
    confidence = greatest(public.occupation_industries.confidence, excluded.confidence),
    weight = greatest(public.occupation_industries.weight, excluded.weight),
    evidence = public.occupation_industries.evidence || excluded.evidence,
    updated_at = now();
end;
$$;

select public.refresh_occupation_industries();

create or replace view public.v_occupation_industries as
select
  oi.occupation_uri,
  e.title_no,
  e.title_en,
  e.code as esco_code,
  e.metadata->>'isco_code' as isco_code,
  i.slug as industry_slug,
  i.name_no as industry_name_no,
  oi.confidence,
  oi.weight,
  oi.source,
  oi.evidence
from public.occupation_industries oi
join public.industries i on i.slug = oi.industry_slug
join public.esco_entities e on e.uri = oi.occupation_uri
where e.entity_type = 'occupation';

create or replace function public.search_esco_occupations(
  search_text text,
  filter_industry_slugs text[] default null,
  result_limit int default 20
)
returns table (
  uri text,
  entity_type text,
  title text,
  title_no text,
  title_en text,
  score real,
  industry_slugs text[],
  industry_names text[]
)
language sql
stable
as $$
  with candidates as (
    select
      e.uri,
      e.entity_type,
      e.title,
      e.title_no,
      e.title_en,
      greatest(
        extensions.similarity(coalesce(e.title, ''), search_text),
        extensions.similarity(coalesce(e.title_no, ''), search_text),
        extensions.similarity(coalesce(e.title_en, ''), search_text),
        coalesce(max(extensions.similarity(l.label, search_text)), 0)
      ) as score
    from public.esco_entities e
    left join public.esco_labels l on l.entity_uri = e.uri
    where e.entity_type = 'occupation'
      and (
        filter_industry_slugs is null
        or cardinality(filter_industry_slugs) = 0
        or exists (
          select 1
          from public.occupation_industries oi
          where oi.occupation_uri = e.uri
            and oi.industry_slug = any(filter_industry_slugs)
        )
      )
    group by e.uri
  )
  select
    c.uri,
    c.entity_type,
    c.title,
    c.title_no,
    c.title_en,
    c.score,
    coalesce(array_agg(distinct i.slug) filter (where i.slug is not null), '{}'::text[]) as industry_slugs,
    coalesce(array_agg(distinct i.name_no) filter (where i.name_no is not null), '{}'::text[]) as industry_names
  from candidates c
  left join public.occupation_industries oi on oi.occupation_uri = c.uri
  left join public.industries i on i.slug = oi.industry_slug
  where c.score > 0.08
  group by c.uri, c.entity_type, c.title, c.title_no, c.title_en, c.score
  order by c.score desc, c.title asc
  limit least(result_limit, 100);
$$;

grant select on public.industries to anon, authenticated;
grant select on public.occupation_industry_rules to authenticated;
grant select on public.occupation_industries to anon, authenticated;
grant select on public.v_occupation_industries to anon, authenticated;
grant execute on function public.search_esco_occupations(text, text[], int) to anon, authenticated;
