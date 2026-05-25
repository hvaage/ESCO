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
DATABASE_URL="postgresql://postgres:YOUR-PASSWORD@db.wcaqfupjatnjwbgatzjv.supabase.co:5432/postgres"
ESCO_LANGUAGE="no"
```

Do not commit `.env`.

## Import ESCO

Install dependencies:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Run a small smoke test first:

```bash
python scripts/import_esco_api.py --limit-occupations 10 --limit-skills 50
```

Then run the full import:

```bash
python scripts/import_esco_api.py
```

The importer reads ESCO through the public API and writes occupations, skills,
labels, and occupation-skill relations into Supabase/Postgres.

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
