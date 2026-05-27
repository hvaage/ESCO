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
- `industries`: curated Norwegian industry filters
- `occupation_industries`: seeded occupation-to-industry mappings
- `ssb_table_metadata` and `ssb_observations`: normalized SSB career-signal observations
- `industry_ssb_mappings`: first-pass mapping from local industries to SSB NACE/fagfelt codes
- `nho_kb_sources` and `nho_kb_observations`: raw NHO Kompetansebarometeret figure data
- `nho_kb_subgroup_mappings`: conservative mapping from NHO groups/counties to local industries and regions
- `nho_competence_signals`: optional manual/import surface for additional NHO signals
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
- first-pass industry filters derived from STYRK prefixes and occupation title rules

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

## Public Career Compass

The public no-login teaser has two frontend-ready Supabase RPCs.

Use `get_public_market_overview` before the user has selected a specific
occupation or competence. It powers the landing-page overview for all Norway /
all industries, and can be re-run when the user chooses region or industry:

```ts
supabase.rpc("get_public_market_overview", {
  filter_region_code: null,
  filter_industry_slug: null,
})
```

It returns a broad visual overview:

- `summary`: title, explanation and key insight texts
- `employer_needs`: latest NHO Kompetansebarometeret signals, including
  `display_signals`, `strongest_signals`, `weakest_signals`,
  `largest_increases`, `largest_decreases` and per-signal trend fields when
  more than one NHO year has been imported
- `industry_trends`: SSB industry employment and development signals
- `regional_signals`: strongest municipalities/areas in the selected scope
- `career_directions`: occupation directions that currently look worth exploring
- `competence_areas`: NHO competence fields plus sample skills from highlighted directions
- `suggested_explorations`: CTA cards for choosing region, industry or occupation
- `data_sources` and `confidence_notes`: source provenance and interpretation caveats

NHO trend fields are intentionally historical. With only the 2025 package
imported, `largest_increases` and `largest_decreases` are empty and
`trend_available` is false. They become populated after a later NHO year is
imported without resetting older years.

Use `get_career_direction_explorer` after the user searches for or selects a
specific occupation/competence:

```ts
supabase.rpc("get_career_direction_explorer", {
  search_text: "sykepleier",
  filter_region_code: null,
  filter_industry_slug: null,
})
```

It returns a frontend-ready JSON payload for the "Utforsk en karriereretning"
experience:

- `summary`: title, description, combined demand score and key insights
- `demand`: SSB/NHO demand components, market signal and employer-demand signals
- `competencies`: must-have and nice-to-have ESCO skills, plus learn-next suggestions
- `industries`: matched industries and national SSB industry signals
- `geography`: regional SSB signals; accepts SSB municipality codes like `K-0301`
  or two-digit county prefixes like `03`
- `nearby_occupations`: transferable career paths with skill overlap, market signal and opportunity quadrant
- `opportunity_matrix`: matrix-ready items that combine market signal and competence overlap
- `visualization`: chart-ready demand bars, skill counts, region ranking, related network and opportunity matrix
- `data_sources` and `confidence_notes`: source provenance and interpretation caveats

The lower-level `get_public_career_compass` RPC is still available as a raw
data payload for debugging and future backend composition.

Import the local SSB JSON-stat2 exports after migrations:

```bash
python scripts/apply_migrations.py
python scripts/import_ssb_career_signals.py \
  --source-dir /Users/henrikvaage/Downloads/norwegian-career-intelligence/data/raw/ssb
```

Validate without writing:

```bash
python scripts/import_ssb_career_signals.py \
  --source-dir /Users/henrikvaage/Downloads/norwegian-career-intelligence/data/raw/ssb \
  --dry-run
```

SSB is also treated as a historical import. Re-running the importer with a new
annual export updates existing table/dimension observations and adds new
periods, without duplicating older observations. Use `--reset-ssb` only for a
deliberate full rebuild from scratch.

Import the NHO Kompetansebarometeret migration package:

```bash
python scripts/apply_migrations.py
python scripts/import_nho_kompetansebarometer.py \
  --zip-path /private/tmp/nho-kompetansebarometer-2025-migreringspakke-20260526-141932.zip
```

Validate without writing:

```bash
python scripts/import_nho_kompetansebarometer.py \
  --zip-path /private/tmp/nho-kompetansebarometer-2025-migreringspakke-20260526-141932.zip \
  --dry-run
```

NHO is an annual historical import. Keep prior years unless you deliberately
need a full rebuild. When the 2026 package arrives, import it without reset:

```bash
python scripts/apply_migrations.py
python scripts/import_nho_kompetansebarometer.py \
  --zip-path /path/to/nho-kompetansebarometer-2026-migreringspakke.zip
```

If an already imported year is corrected, replace only that year:

```bash
python scripts/import_nho_kompetansebarometer.py \
  --zip-path /path/to/nho-kompetansebarometer-2026-migreringspakke.zip \
  --replace-year 2026
```

Use `--reset-nho` only for a deliberate full NHO rebuild. The public compass
uses the latest imported NHO year by default, while
`v_nho_compass_signal_year_trends` retains all imported years for development
over time.

NHO data are imported in two layers:

- raw `nho_kb_sources` / `nho_kb_observations` for traceability
- curated public views such as `v_nho_unmet_need_signals`,
  `v_nho_competence_field_signals`, `v_nho_education_level_signals` and
  `v_nho_skill_weight_signals`

Do not freely cross NHO dimensions. The public XLSX files are aggregated figure
data, not respondent-level data. Product views only combine dimensions that are
present in the same published source row.

## Industry Filters

Industries are stored as a local filter layer, not as official ESCO data.

Frontend clients can read:

- `industries`
- `v_occupation_industries`

For occupation search with industry filtering, use:

```ts
supabase.rpc("search_esco_occupations", {
  search_text: "sykepleier",
  filter_industry_slugs: ["helse_omsorg"],
  result_limit: 10,
})
```

Use an empty array or `null` for `filter_industry_slugs` to search across all
industries.

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
