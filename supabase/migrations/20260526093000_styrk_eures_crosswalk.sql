create table if not exists public.esco_data_versions (
  id text primary key,
  source text not null,
  version text not null,
  language text,
  downloaded_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb
);

create table if not exists public.styrk08 (
  code text primary key,
  parent_code text references public.styrk08(code) deferrable initially deferred,
  level smallint not null check (level between 1 and 4),
  name text not null,
  notes text
);

alter table public.styrk08 drop constraint if exists styrk08_parent_code_fkey;
alter table public.styrk08
  add constraint styrk08_parent_code_fkey
  foreign key (parent_code)
  references public.styrk08(code)
  deferrable initially deferred;

create index if not exists styrk08_parent_code_idx on public.styrk08(parent_code);
create index if not exists styrk08_level_idx on public.styrk08(level);
create index if not exists styrk08_name_trgm_idx
  on public.styrk08 using gin (name extensions.gin_trgm_ops);

alter table public.esco_occupation_skills
  add column if not exists source_version text;

create table if not exists public.esco_styrk_mappings (
  occupation_uri text not null references public.esco_entities(uri) on delete cascade,
  styrk_code text not null references public.styrk08(code) on delete restrict,
  mapping_relation text not null,
  source text not null,
  source_esco_version text not null,
  source_styrk_version text,
  confidence smallint not null check (confidence between 1 and 5),
  editorial_note text,
  created_at timestamptz not null default now(),
  primary key (occupation_uri, styrk_code, mapping_relation, source)
);

create index if not exists esco_styrk_mappings_styrk_idx
  on public.esco_styrk_mappings(styrk_code);
create index if not exists esco_styrk_mappings_relation_idx
  on public.esco_styrk_mappings(mapping_relation);

create table if not exists public.esco_occupation_aliases (
  id bigserial primary key,
  occupation_uri text not null references public.esco_entities(uri) on delete cascade,
  alias text not null,
  alias_normalized text not null,
  language text not null default 'no',
  alias_type text not null check (alias_type in (
    'esco_preferred',
    'esco_alternative',
    'styrk_title',
    'eures_label',
    'isco_group'
  )),
  source text not null,
  source_relation text,
  weight smallint not null default 3 check (weight between 1 and 5),
  created_at timestamptz not null default now(),
  unique (occupation_uri, alias_normalized, alias_type, source)
);

create index if not exists esco_occupation_aliases_alias_idx
  on public.esco_occupation_aliases(alias_normalized);
create index if not exists esco_occupation_aliases_alias_trgm_idx
  on public.esco_occupation_aliases using gin (alias extensions.gin_trgm_ops);

create or replace view public.v_esco_styrk_occupations as
select
  e.uri as occupation_uri,
  e.title_no,
  e.title_en,
  e.code as esco_code,
  e.metadata->>'isco_code' as isco_code,
  m.styrk_code,
  s.name as styrk_title,
  m.mapping_relation,
  m.source,
  m.confidence
from public.esco_entities e
join public.esco_styrk_mappings m on m.occupation_uri = e.uri
join public.styrk08 s on s.code = m.styrk_code
where e.entity_type = 'occupation';
