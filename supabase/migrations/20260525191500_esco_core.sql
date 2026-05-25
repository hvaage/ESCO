create extension if not exists pg_trgm with schema extensions;
create extension if not exists unaccent with schema extensions;
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.esco_entities (
  uri text primary key,
  entity_type text not null check (entity_type in ('occupation', 'skill')),
  code text,
  title text not null,
  title_no text,
  title_en text,
  description_no text,
  description_en text,
  skill_type text,
  status text,
  metadata jsonb not null default '{}'::jsonb,
  fetched_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.esco_labels (
  id bigserial primary key,
  entity_uri text not null references public.esco_entities(uri) on delete cascade,
  language text not null,
  label_type text not null check (label_type in ('preferred', 'alternative')),
  label text not null,
  created_at timestamptz not null default now(),
  unique (entity_uri, language, label_type, label)
);

create table if not exists public.esco_occupation_skills (
  occupation_uri text not null references public.esco_entities(uri) on delete cascade,
  skill_uri text not null references public.esco_entities(uri) on delete cascade,
  relation_type text not null check (relation_type in ('essential', 'optional')),
  skill_type text,
  created_at timestamptz not null default now(),
  primary key (occupation_uri, skill_uri, relation_type)
);

create table if not exists public.job_leads (
  id uuid primary key default gen_random_uuid(),
  user_id uuid,
  source text not null check (source in ('nav', 'linkedin', 'manual', 'other')),
  external_id text,
  title text not null,
  company_name text,
  description text,
  location_text text,
  county text,
  municipality text,
  url text,
  raw_payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (source, external_id)
);

create table if not exists public.job_skill_requirements (
  id uuid primary key default gen_random_uuid(),
  job_lead_id uuid not null references public.job_leads(id) on delete cascade,
  skill_uri text references public.esco_entities(uri) on delete set null,
  skill_label text not null,
  requirement_source text not null check (requirement_source in ('explicit_ad_text', 'esco_occupation_essential', 'esco_occupation_optional', 'llm_inferred')),
  evidence text,
  confidence numeric(5,4) not null default 0.5000 check (confidence >= 0 and confidence <= 1),
  weight numeric(8,4) not null default 1,
  created_at timestamptz not null default now()
);

create table if not exists public.candidate_skill_claims (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  skill_uri text references public.esco_entities(uri) on delete set null,
  skill_label text not null,
  evidence_source text not null check (evidence_source in ('cv', 'linkedin', 'manual', 'course', 'certification', 'assessment', 'other')),
  evidence text,
  proficiency_level text,
  confidence numeric(5,4) not null default 0.5000 check (confidence >= 0 and confidence <= 1),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.candidate_job_skill_gaps (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  job_lead_id uuid not null references public.job_leads(id) on delete cascade,
  skill_uri text references public.esco_entities(uri) on delete set null,
  skill_label text not null,
  gap_type text not null check (gap_type in ('strength', 'partial_gap', 'gap', 'unknown')),
  importance_score numeric(10,4) not null default 0,
  match_confidence numeric(5,4) not null default 0.5000 check (match_confidence >= 0 and match_confidence <= 1),
  explanation text,
  created_at timestamptz not null default now(),
  unique (user_id, job_lead_id, skill_label)
);

create index if not exists esco_entities_type_idx on public.esco_entities(entity_type);
create index if not exists esco_entities_title_trgm_idx on public.esco_entities using gin (title extensions.gin_trgm_ops);
create index if not exists esco_entities_title_no_trgm_idx on public.esco_entities using gin (title_no extensions.gin_trgm_ops);
create index if not exists esco_entities_title_en_trgm_idx on public.esco_entities using gin (title_en extensions.gin_trgm_ops);
create index if not exists esco_labels_label_trgm_idx on public.esco_labels using gin (label extensions.gin_trgm_ops);
create index if not exists esco_occupation_skills_occ_idx on public.esco_occupation_skills(occupation_uri);
create index if not exists esco_occupation_skills_skill_idx on public.esco_occupation_skills(skill_uri);
create index if not exists job_skill_requirements_job_idx on public.job_skill_requirements(job_lead_id);
create index if not exists candidate_skill_claims_user_idx on public.candidate_skill_claims(user_id);
create index if not exists candidate_job_skill_gaps_user_job_idx on public.candidate_job_skill_gaps(user_id, job_lead_id);

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists set_esco_entities_updated_at on public.esco_entities;
create trigger set_esco_entities_updated_at
before update on public.esco_entities
for each row execute function public.set_updated_at();

drop trigger if exists set_job_leads_updated_at on public.job_leads;
create trigger set_job_leads_updated_at
before update on public.job_leads
for each row execute function public.set_updated_at();

drop trigger if exists set_candidate_skill_claims_updated_at on public.candidate_skill_claims;
create trigger set_candidate_skill_claims_updated_at
before update on public.candidate_skill_claims
for each row execute function public.set_updated_at();

create or replace view public.v_esco_occupation_skill_counts as
select
  o.uri as occupation_uri,
  o.title_no,
  o.title_en,
  count(*) filter (where os.relation_type = 'essential') as essential_skill_count,
  count(*) filter (where os.relation_type = 'optional') as optional_skill_count,
  count(*) as total_skill_count
from public.esco_entities o
left join public.esco_occupation_skills os on os.occupation_uri = o.uri
where o.entity_type = 'occupation'
group by o.uri, o.title_no, o.title_en;

create or replace function public.search_esco_entities(
  query text,
  wanted_type text default null,
  result_limit int default 20
)
returns table (
  uri text,
  entity_type text,
  title text,
  title_no text,
  title_en text,
  score real
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
        extensions.similarity(coalesce(e.title, ''), query),
        extensions.similarity(coalesce(e.title_no, ''), query),
        extensions.similarity(coalesce(e.title_en, ''), query),
        coalesce(max(extensions.similarity(l.label, query)), 0)
      ) as score
    from public.esco_entities e
    left join public.esco_labels l on l.entity_uri = e.uri
    where wanted_type is null or e.entity_type = wanted_type
    group by e.uri
  )
  select *
  from candidates
  where score > 0.08
  order by score desc, title asc
  limit least(result_limit, 100);
$$;
