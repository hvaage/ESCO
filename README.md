# ESCO Supabase

ESCO database over occupations, skills and skill-gap matching for karrierenmin.no.

This repo is designed to make ESCO the shared competence language between:

- NAV job ads
- user LinkedIn job leads
- user CVs and skill profiles
- NHO competence-demand data
- learning opportunities and certifications

## What This Stores

The first migration creates:

- `esco_entities`: ESCO occupations and skills
- `esco_labels`: multilingual preferred and alternative labels
- `esco_occupation_skills`: essential/optional skill relations for occupations
- `styrk08`: Norwegian STYRK-08 hierarchy
- `esco_styrk_mappings`: EURES/derived mapping from ESCO occupations to STYRK-08
- `esco_occupation_aliases`: weighted Norwegian occupation aliases from ESCO, EURES and STYRK
- `job_leads`: job ads or user-saved job leads
- `job_skill_requirements`: skills extracted from job leads
- `candidate_skill_claims`: skills extracted from a user's CV/profile
- `candidate_job_skill_gaps`: materialized gap-analysis results

The goal is to answer questions like:

> What does this job require, what does the candidate already document, and what are the most valuable missing skills?

## Supabase Setup

```bash
supabase login
supabase init
supabase link --project-ref wcaqfupjatnjwbgatzjv
supabase db push
```

For direct import, create a local `.env` file:

```bash
DATABASE_URL="postgresql://postgres.wcaqfupjatnjwbgatzjv:YOUR-PASSWORD@aws-1-eu-west-2.pooler.supabase.com:5432/postgres?sslmode=require"
ESCO_LANGUAGE="no"
ESCO_VERSION="v1.2.1"
```

Do not commit `.env`.

Supabase direct database hosts can be IPv6-only. If
`db.wcaqfupjatnjwbgatzjv.supabase.co` fails to resolve locally, use the pooler
URL from `supabase/.temp/pooler-url` or the Supabase dashboard instead.

## Import ESCO + STYRK

Install dependencies:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

The recommended full import uses a generated CSV package under `data/`. This is
faster and more reproducible than calling the ESCO API during database import.

Validate the package first:

```bash
python scripts/import_esco_styrk_csv.py --dry-run
```

Apply schema migrations, then import the complete reference dataset:

```bash
supabase db push
python scripts/import_esco_styrk_csv.py --reset-reference-data
```

If the Supabase CLI is not linked, the same migrations can be applied directly
with `DATABASE_URL`:

```bash
python scripts/apply_migrations.py
python scripts/import_esco_styrk_csv.py --reset-reference-data
```

This imports:

- ESCO v1.2.1 occupations and skills in Norwegian
- essential and optional occupation-skill relations
- STYRK-08 hierarchy
- EURES Norway occupation mapping, documented as ESCO v1.0.8 source data
- low-confidence ISCO/STYRK fallback mappings for current ESCO occupations not covered by EURES
- weighted Norwegian aliases for occupation matching

The legacy API importer can still be used for small smoke tests:

```bash
python scripts/import_esco_api.py --limit-occupations 10 --limit-skills 50
```

Or, if you explicitly want to rebuild ESCO from the live API:

```bash
python scripts/import_esco_api.py
```

The API importer pins `selectedVersion=v1.2.1` by default. It does not import the
STYRK/EURES crosswalk; use the CSV importer for the Norwegian full version.

## Matching Flow

Recommended production flow:

1. Parse a job ad into title, description, explicit requirements and location.
2. Match title to one or more `esco_entities` where `entity_type = 'occupation'`.
3. Add ESCO `essential` and `optional` skills from `esco_occupation_skills`.
4. Extract explicit skill mentions from the job ad and map them to ESCO skills.
5. Parse the user's CV/profile into `candidate_skill_claims`.
6. Compare requirements against claims.
7. Rank gaps by:
   - explicitly mentioned in job ad
   - ESCO essential vs optional
   - frequency in NAV/LinkedIn leads
   - NHO regional demand
   - confidence of the CV evidence
   - availability of relevant learning opportunities

## Notes

ESCO is a taxonomy, not a complete recommendation engine. It provides the stable
occupation and skill identifiers. The ranking layer should combine ESCO with job
ad evidence, NHO demand data, user CV evidence and course/certification data.
