# Matching Architecture

## Purpose

ESCO should act as the stable competence graph. It gives each occupation and
skill a URI that can be shared across NAV ads, LinkedIn leads, CV parsing, NHO
demand data and learning recommendations.

## Recommended Matching Layers

### 1. Occupation Match

Input:

- job title
- job description
- occupation hints from NAV/STYRK if available

Output:

- one or more ESCO occupations
- confidence per occupation

Use ESCO occupation labels as candidates, but let an LLM or ranking model choose
between close titles when needed.

### 2. Skill Extraction

Extract two sets of skills:

- explicit skills from the ad text
- typical ESCO skills from the matched occupation

Keep these separate. Explicit skills should usually rank above generic occupation
skills.

### 3. CV Skill Evidence

Parse CV/profile into skill claims:

- direct evidence, e.g. "Python", "Azure", "fagbrev"
- inferred evidence, e.g. projects, job titles, responsibilities
- evidence source and confidence

Do not treat inferred claims as equal to documented certifications or concrete
work experience.

### 4. Gap Analysis

For each job skill requirement:

- `strength`: user has strong matching evidence
- `partial_gap`: user has adjacent or weak evidence
- `gap`: no matching evidence
- `unknown`: insufficient evidence

### 5. Recommendation Ranking

Rank missing skills with:

- job ad explicitness
- ESCO essential/optional relation
- frequency in saved LinkedIn leads
- frequency in NAV ads
- NHO regional/industry demand
- realistic learning path availability
- user profile fit

## Important Limitation

ESCO describes common skill relationships for occupations. It does not prove that
a specific employer requires every ESCO essential skill, nor that a certification
will increase job probability. Use ESCO as structure, job ads as current demand,
and NHO data as regional/industry signal.
