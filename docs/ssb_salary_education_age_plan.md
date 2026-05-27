# SSB salary tables 11420 and 11421

## Tables

- `11420`: Monthly salary by statistic, sector, education level, industry
  (`NACE2007`), gender, agreed working time, variable and year.
- `11421`: Monthly salary by statistic, sector, industry (`NACE2007`), age,
  gender, agreed working time, variable and year.

Both tables share:

- `MaaleMetode`
- `Sektor`
- `NACE2007`
- `Kjonn`
- `ArbeidsTid`
- `ContentsCode`
- `Tid`

They differ in the personal dimension:

- `11420` has `UtdanNivaa`
- `11421` has `Alder`

## Recommended product use

Use the two tables side by side as official SSB indicators:

1. Education-adjusted salary benchmark:
   - table `11420`
   - filter by industry, sector, gender, working time and education level
   - show median, lower quartile and upper quartile monthly salary

2. Age curve benchmark:
   - table `11421`
   - filter by industry, sector, gender, working time and age group
   - show median, lower quartile and upper quartile monthly salary

Do not present an official salary cell for education + age combined. SSB does
not publish that cross-tabulation in these two tables.

## Optional derived estimate

If a combined "education and age adjusted" figure is useful, compute it as a
clearly labelled estimate:

```text
base = median salary for all education / all ages in selected industry
education_index = median(education level) / median(all education)
age_index = median(age group) / median(all ages)
estimated_salary = base * education_index * age_index
```

This must be shown as:

```text
Modellert estimat basert på to separate SSB-tabeller. Ikke en offisiell SSB-celle.
```

Use counts (`Antall arbeidsforhold med lønn`) to suppress or soften estimates
where the underlying observations are sparse.

## Data model recommendation

The existing generic `ssb_observations` table can store both tables. Extend the
salary importer to support:

- `11420`: selected latest year, median, average, lower quartile, upper quartile
  and employment-count metrics across all education levels, NACE groups, sectors,
  gender and working-time categories.
- `11421`: selected latest year, same metrics across all age groups, NACE groups,
  sectors, gender and working-time categories.

Then add a public RPC such as:

```sql
get_public_salary_profile(
  filter_industry_slug text,
  filter_nace_code text,
  education_level text,
  age_group text,
  gender text,
  sector text,
  working_time text
)
```

The RPC should return:

- `education_benchmark` from `11420`
- `age_benchmark` from `11421`
- `combined_estimate` only when both parts have enough observations
- `method_notes`
- `data_sources`

## UI copy

Use:

- "Lønnsnivå etter utdanning"
- "Lønnskurve etter alder"
- "Modellert lønnsestimat"

Avoid:

- "fasit"
- "prognose"
- "garantert lønn"
- "SSB sier at du får"
