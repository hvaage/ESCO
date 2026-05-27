create or replace function public.get_public_market_overview(
  filter_region_code text default null,
  filter_industry_slug text default null
)
returns jsonb
language plpgsql
stable
as $$
declare
  selected_industry record;
  selected_region_label text;
  nho_region_code text;
  latest_nho_year integer;
  scope_title text;
  employer_needs jsonb;
  industry_trends jsonb;
  regional_signals jsonb;
  career_directions jsonb;
  competence_areas jsonb;
  suggested_explorations jsonb;
  data_source_cards jsonb;
  top_region jsonb;
  top_industry jsonb;
  top_need jsonb;
  top_direction jsonb;
  insight_messages jsonb;
  summary_title text;
begin
  select *
  into selected_industry
  from public.industries i
  where i.slug = filter_industry_slug
  limit 1;

  nho_region_code := case
    when filter_region_code ~ '^[0-9]{2}$' then filter_region_code
    when filter_region_code ~ '^K-[0-9]{4}$' then substring(filter_region_code from 3 for 2)
    else null
  end;

  select max(year)
  into latest_nho_year
  from public.nho_kb_sources;

  select coalesce(
    (
      select max(region_label)
      from public.nho_kb_subgroup_mappings
      where region_code = nho_region_code
    ),
    (
      select max(o.dimension_labels->>'Region')
      from public.ssb_observations o
      where o.table_id = '11615'
        and o.dimension_codes->>'Region' = filter_region_code
    )
  )
  into selected_region_label;

  selected_region_label := nullif(trim(split_part(selected_region_label, ' - ', 1)), '');

  scope_title := case
    when selected_industry.slug is not null and selected_region_label is not null
      then selected_industry.name_no || ' · ' || selected_region_label
    when selected_industry.slug is not null
      then selected_industry.name_no
    when selected_region_label is not null
      then selected_region_label
    else 'Hele Norge og alle bransjer'
  end;

  summary_title := case
    when selected_industry.slug is not null and selected_region_label is not null
      then 'Dette peker seg ut i ' || selected_industry.name_no || ' i ' || selected_region_label
    when selected_industry.slug is not null
      then 'Dette peker seg ut i ' || selected_industry.name_no
    when selected_region_label is not null
      then 'Dette peker seg ut i ' || selected_region_label
    else 'Dette peker seg ut i Norge akkurat nå'
  end;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'type', x.signal_type,
        'label', x.signal_label,
        'value', x.signal_value,
        'high_intensity_value', x.high_intensity_value,
        'level', case
          when x.signal_value >= 70 then 'high'
          when x.signal_value >= 40 then 'medium'
          when x.signal_value > 0 then 'low'
          else 'unknown'
        end,
        'year', x.year,
        'previous_year', x.previous_year,
        'previous_value', x.previous_signal_value,
        'previous_signal_value', x.previous_signal_value,
        'value_change', x.signal_change,
        'signal_change', x.signal_change,
        'percent_change', x.signal_change_percent,
        'signal_change_percent', x.signal_change_percent,
        'trend_available', x.previous_year is not null,
        'trend_direction', case
          when x.signal_change > 0 then 'up'
          when x.signal_change < 0 then 'down'
          when x.signal_change = 0 then 'flat'
          else 'unknown'
        end,
        'scope_relevance', x.relevance_order,
        'scope', coalesce(x.industry_name_no, x.region_label, 'Nasjonalt'),
        'industry_slug', x.industry_slug,
        'industry_name_no', x.industry_name_no,
        'region_code', x.region_code,
        'region_label', x.region_label,
        'sample_base', x.sample_base,
        'confidence', x.confidence,
        'source', 'NHO Kompetansebarometeret'
      )
      order by x.relevance_order, x.signal_type_order, x.signal_value desc nulls last
    ),
    '[]'::jsonb
  )
  into top_need
  from (
    with scoped_signals as (
      select
        trends.*,
        case
          when filter_industry_slug is not null and trends.industry_slug = filter_industry_slug then 1
          when nho_region_code is not null and trends.region_code = nho_region_code then 2
          when trends.industry_slug is null and trends.region_code is null then 3
          else 4
        end as relevance_order,
        case trends.signal_type
          when 'nho_unmet_need' then 1
          when 'nho_competence_field_need' then 2
          when 'nho_education_level_need' then 3
          when 'nho_recruitment_skill_weight' then 4
          else 9
        end as signal_type_order
      from public.v_nho_compass_signal_year_trends trends
      where trends.year = latest_nho_year
        and trends.signal_value is not null
        and (
          filter_industry_slug is null
          or trends.industry_slug is null
          or trends.industry_slug = filter_industry_slug
        )
        and (
          (nho_region_code is null and trends.region_code is null)
          or (
            nho_region_code is not null
            and (trends.region_code is null or trends.region_code = nho_region_code)
          )
        )
    ),
    ranked_signals as (
      select
        scoped_signals.*,
        row_number() over (
          partition by
            scoped_signals.signal_type,
            coalesce(scoped_signals.industry_slug, 'national'),
            coalesce(scoped_signals.region_code, 'national')
          order by
            case when scoped_signals.sample_base >= 30 then 0 else 1 end,
            scoped_signals.signal_value desc nulls last,
            scoped_signals.confidence desc
        ) as signal_rank
      from scoped_signals
    )
    select *
    from ranked_signals
    where signal_rank <= 8
    order by
      relevance_order,
      signal_type_order,
      signal_value desc nulls last
    limit 48
  ) x;

  employer_needs := jsonb_build_object(
    'latest_year', latest_nho_year,
    'signals', coalesce(top_need, '[]'::jsonb),
    'display_signals', coalesce((
      select jsonb_agg(signal order by nullif(signal->>'scope_relevance', '')::integer asc nulls last, nullif(signal->>'value', '')::numeric desc nulls last)
      from (
        select signal
        from (
          select distinct on (signal->>'type', lower(trim(signal->>'label')))
            signal
          from jsonb_array_elements(coalesce(top_need, '[]'::jsonb)) signals(signal)
          where signal->>'type' <> 'nho_unmet_need'
            and lower(trim(signal->>'label')) <> 'udekket kompetansebehov'
          order by
            signal->>'type',
            lower(trim(signal->>'label')),
            nullif(signal->>'scope_relevance', '')::integer asc nulls last,
            nullif(signal->>'value', '')::numeric desc nulls last
        ) deduped
        order by nullif(signal->>'scope_relevance', '')::integer asc nulls last, nullif(signal->>'value', '')::numeric desc nulls last
        limit 24
      ) display
    ), '[]'::jsonb),
    'strongest_signals', coalesce((
      select jsonb_agg(signal order by nullif(signal->>'scope_relevance', '')::integer asc nulls last, nullif(signal->>'value', '')::numeric desc nulls last)
      from (
        select signal
        from (
          select distinct on (signal->>'type', lower(trim(signal->>'label')))
            signal
          from jsonb_array_elements(coalesce(top_need, '[]'::jsonb)) signals(signal)
          where signal->>'type' <> 'nho_unmet_need'
            and lower(trim(signal->>'label')) <> 'udekket kompetansebehov'
            and nullif(signal->>'value', '')::numeric is not null
          order by
            signal->>'type',
            lower(trim(signal->>'label')),
            nullif(signal->>'scope_relevance', '')::integer asc nulls last,
            nullif(signal->>'value', '')::numeric desc nulls last
        ) deduped
        order by nullif(signal->>'scope_relevance', '')::integer asc nulls last, nullif(signal->>'value', '')::numeric desc nulls last
        limit 12
      ) strongest
    ), '[]'::jsonb),
    'weakest_signals', coalesce((
      select jsonb_agg(signal order by nullif(signal->>'scope_relevance', '')::integer asc nulls last, nullif(signal->>'value', '')::numeric asc nulls last)
      from (
        select signal
        from (
          select distinct on (signal->>'type', lower(trim(signal->>'label')))
            signal
          from jsonb_array_elements(coalesce(top_need, '[]'::jsonb)) signals(signal)
          where signal->>'type' <> 'nho_unmet_need'
            and lower(trim(signal->>'label')) <> 'udekket kompetansebehov'
            and nullif(signal->>'value', '')::numeric > 0
          order by
            signal->>'type',
            lower(trim(signal->>'label')),
            nullif(signal->>'scope_relevance', '')::integer asc nulls last,
            nullif(signal->>'value', '')::numeric asc nulls last
        ) deduped
        order by nullif(signal->>'scope_relevance', '')::integer asc nulls last, nullif(signal->>'value', '')::numeric asc nulls last
        limit 12
      ) weakest
    ), '[]'::jsonb),
    'largest_increases', coalesce((
      select jsonb_agg(signal order by nullif(signal->>'scope_relevance', '')::integer asc nulls last, nullif(signal->>'signal_change', '')::numeric desc nulls last)
      from (
        select signal
        from (
          select distinct on (signal->>'type', lower(trim(signal->>'label')))
            signal
          from jsonb_array_elements(coalesce(top_need, '[]'::jsonb)) signals(signal)
          where signal->>'type' <> 'nho_unmet_need'
            and lower(trim(signal->>'label')) <> 'udekket kompetansebehov'
            and nullif(signal->>'signal_change', '')::numeric > 0
          order by
            signal->>'type',
            lower(trim(signal->>'label')),
            nullif(signal->>'scope_relevance', '')::integer asc nulls last,
            nullif(signal->>'signal_change', '')::numeric desc nulls last
        ) deduped
        order by nullif(signal->>'scope_relevance', '')::integer asc nulls last, nullif(signal->>'signal_change', '')::numeric desc nulls last
        limit 12
      ) increases
    ), '[]'::jsonb),
    'largest_decreases', coalesce((
      select jsonb_agg(signal order by nullif(signal->>'scope_relevance', '')::integer asc nulls last, nullif(signal->>'signal_change', '')::numeric asc nulls last)
      from (
        select signal
        from (
          select distinct on (signal->>'type', lower(trim(signal->>'label')))
            signal
          from jsonb_array_elements(coalesce(top_need, '[]'::jsonb)) signals(signal)
          where signal->>'type' <> 'nho_unmet_need'
            and lower(trim(signal->>'label')) <> 'udekket kompetansebehov'
            and nullif(signal->>'signal_change', '')::numeric < 0
          order by
            signal->>'type',
            lower(trim(signal->>'label')),
            nullif(signal->>'scope_relevance', '')::integer asc nulls last,
            nullif(signal->>'signal_change', '')::numeric asc nulls last
        ) deduped
        order by nullif(signal->>'scope_relevance', '')::integer asc nulls last, nullif(signal->>'signal_change', '')::numeric asc nulls last
        limit 12
      ) decreases
    ), '[]'::jsonb),
    'trend_available', exists (
      select 1
      from jsonb_array_elements(coalesce(top_need, '[]'::jsonb)) signals(signal)
      where (signal->>'trend_available')::boolean is true
    ),
    'unmet_need', coalesce((
      select jsonb_agg(signal order by nullif(signal->>'value', '')::numeric desc nulls last)
      from jsonb_array_elements(coalesce(top_need, '[]'::jsonb)) signals(signal)
      where signal->>'type' = 'nho_unmet_need'
    ), '[]'::jsonb),
    'competence_fields', coalesce((
      select jsonb_agg(signal order by nullif(signal->>'value', '')::numeric desc nulls last)
      from jsonb_array_elements(coalesce(top_need, '[]'::jsonb)) signals(signal)
      where signal->>'type' = 'nho_competence_field_need'
    ), '[]'::jsonb),
    'education_levels', coalesce((
      select jsonb_agg(signal order by nullif(signal->>'value', '')::numeric desc nulls last)
      from jsonb_array_elements(coalesce(top_need, '[]'::jsonb)) signals(signal)
      where signal->>'type' = 'nho_education_level_need'
    ), '[]'::jsonb),
    'interpretation', 'Arbeidsgiveres rapporterte behov. Aggregert signal, ikke fasit for enkeltyrker.',
    'trend_interpretation', 'Endringsfeltene viser utvikling fra forrige importerte NHO-år når historikk finnes.'
  );

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'slug', ins.industry_slug,
        'name', ins.industry_name_no,
        'latest_year', ins.latest_period_year,
        'employed_latest', ins.employed_latest,
        'previous_year', ins.previous_period_year,
        'employed_previous', ins.employed_previous,
        'absolute_change', ins.absolute_change,
        'percent_change', ins.percent_change,
        'mapping_confidence', ins.mapping_confidence,
        'source', 'Statistisk sentralbyrå'
      )
      order by ins.employed_latest desc nulls last
    ),
    '[]'::jsonb
  )
  into top_industry
  from (
    select *
    from public.v_industry_national_signals
    where filter_industry_slug is null
       or industry_slug = filter_industry_slug
    order by employed_latest desc nulls last
    limit case when filter_industry_slug is null then 8 else 1 end
  ) ins;

  industry_trends := jsonb_build_object(
    'items', coalesce(top_industry, '[]'::jsonb),
    'growth_leaders', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.percent_change desc nulls last)
      from (
        select *
        from public.v_industry_national_signals
        where (filter_industry_slug is null or industry_slug = filter_industry_slug)
          and percent_change is not null
        order by percent_change desc nulls last
        limit case when filter_industry_slug is null then 5 else 1 end
      ) x
    ), '[]'::jsonb),
    'source', 'Statistisk sentralbyrå',
    'interpretation', 'Sysselsetting og utvikling i brede næringer. Indikator, ikke prognose.'
  );

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'region_code', r.region_code,
        'region_label', r.region_label,
        'latest_year', r.latest_period_year,
        'employed_latest', r.employed_latest,
        'previous_year', r.previous_period_year,
        'employed_previous', r.employed_previous,
        'absolute_change', r.absolute_change,
        'percent_change', r.percent_change,
        'region_signal_score', r.region_signal_score,
        'source', 'Statistisk sentralbyrå'
      )
      order by r.region_signal_score desc nulls last, r.employed_latest desc nulls last
    ),
    '[]'::jsonb
  )
  into top_region
  from (
    with field_filter as (
      select distinct ism.ssb_code
      from public.industry_ssb_mappings ism
      where ism.mapping_type = 'fagfelt'
        and ism.ssb_table_id = '11615'
        and ism.industry_slug = filter_industry_slug
    ),
    base as (
      select
        o.dimension_codes->>'Region' as region_code,
        max(o.dimension_labels->>'Region') as region_label,
        o.period_year,
        sum(o.value) as employed_value
      from public.ssb_observations o
      where o.table_id = '11615'
        and o.metric_code = 'SysselsatteArbSted'
        and (o.dimension_codes->>'Region') ~ '^K-[0-9]{4}$'
        and o.period_year is not null
        and o.value is not null
        and (
          filter_industry_slug is null
          or o.dimension_codes->>'Fagfelt' in (select ssb_code from field_filter)
        )
        and (
          filter_region_code is null
          or length(trim(filter_region_code)) = 0
          or o.dimension_codes->>'Region' = filter_region_code
          or (
            filter_region_code ~ '^[0-9]{2}$'
            and o.dimension_codes->>'Region' like ('K-' || filter_region_code || '%')
          )
        )
      group by o.dimension_codes->>'Region', o.period_year
    ),
    with_previous as (
      select
        b.*,
        lag(b.employed_value) over (partition by b.region_code order by b.period_year) as previous_value,
        lag(b.period_year) over (partition by b.region_code order by b.period_year) as previous_period_year,
        row_number() over (partition by b.region_code order by b.period_year desc) as recency_rank
      from base b
    ),
    latest as (
      select
        wp.*,
        case
          when wp.previous_value is null or wp.previous_value = 0 then null
          else ((wp.employed_value - wp.previous_value) / wp.previous_value) * 100
        end as percent_change,
        max(wp.employed_value) over () as max_employed_value
      from with_previous wp
      where recency_rank = 1
    )
    select
      region_code,
      trim(split_part(region_label, ' - ', 1)) as region_label,
      period_year as latest_period_year,
      round(employed_value::numeric, 2) as employed_latest,
      previous_period_year,
      round(coalesce(previous_value, 0)::numeric, 2) as employed_previous,
      round((employed_value - coalesce(previous_value, employed_value))::numeric, 2) as absolute_change,
      round(percent_change::numeric, 2) as percent_change,
      round(
        least(
          100,
          greatest(
            0,
            (
              (coalesce(employed_value / nullif(max_employed_value, 0), 0) * 70)
              + (least(1, greatest(0, (coalesce(percent_change, 0) + 5) / 10)) * 30)
            )
          )
        )::numeric,
        2
      ) as region_signal_score
    from latest
    order by region_signal_score desc nulls last, employed_value desc nulls last
    limit case
      when filter_region_code is null or length(trim(filter_region_code)) = 0 then 10
      else 12
    end
  ) r;

  regional_signals := jsonb_build_object(
    'items', coalesce(top_region, '[]'::jsonb),
    'source', 'Statistisk sentralbyrå',
    'interpretation', case
      when filter_industry_slug is null then 'Områder med høy sysselsetting og utvikling i datagrunnlaget.'
      else 'Områder med høy sysselsetting og utvikling i fagfelt knyttet til valgt bransje.'
    end
  );

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'occupation_uri', d.occupation_uri,
        'title', d.title_no,
        'market_signal_score', d.market_signal_score,
        'market_signal_level', d.market_signal_level,
        'direction_score', d.direction_score,
        'latest_year', d.latest_period_year,
        'employed_latest_thousands', d.employed_latest_thousands,
        'percent_change', d.percent_change,
        'industries', d.industries,
        'regional_signal', d.regional_signal,
        'source', 'Statistisk sentralbyrå og yrkes-/kompetansedata'
      )
      order by d.direction_score desc nulls last, d.market_signal_score desc nulls last
    ),
    '[]'::jsonb
  )
  into top_direction
  from (
    with candidate_market as (
      select ms.*
      from public.v_occupation_market_signals ms
      where (
        filter_industry_slug is null
        or exists (
          select 1
          from public.occupation_industries oi
          where oi.occupation_uri = ms.occupation_uri
            and oi.industry_slug = filter_industry_slug
        )
      )
      order by
        ms.market_signal_score desc nulls last,
        ms.employed_latest_thousands desc nulls last
      limit case
        when filter_region_code is null or length(trim(filter_region_code)) = 0 then 36
        else 80
      end
    ),
    industry_labels as (
      select
        oi.occupation_uri,
        jsonb_agg(
          jsonb_build_object(
            'slug', oi.industry_slug,
            'name', i.name_no,
            'confidence', oi.confidence
          )
          order by oi.confidence desc, i.sort_order
        ) as industries
      from public.occupation_industries oi
      join candidate_market cm on cm.occupation_uri = oi.occupation_uri
      join public.industries i on i.slug = oi.industry_slug
      group by oi.occupation_uri
    ),
    regional_occupation_base as (
      select
        cm.occupation_uri,
        o.dimension_codes->>'Region' as region_code,
        max(trim(split_part(o.dimension_labels->>'Region', ' - ', 1))) as region_label,
        o.period_year,
        sum(o.value * oi.confidence * ism.confidence) as employed_value
      from candidate_market cm
      join public.occupation_industries oi on oi.occupation_uri = cm.occupation_uri
      join public.industry_ssb_mappings ism
        on ism.industry_slug = oi.industry_slug
       and ism.mapping_type = 'fagfelt'
       and ism.ssb_table_id = '11615'
      join public.ssb_observations o
        on o.table_id = '11615'
       and o.metric_code = 'SysselsatteArbSted'
       and o.dimension_codes->>'Fagfelt' = ism.ssb_code
      where filter_region_code is not null
        and length(trim(filter_region_code)) > 0
        and o.period_year is not null
        and o.value is not null
        and (
          o.dimension_codes->>'Region' = filter_region_code
          or (
            filter_region_code ~ '^[0-9]{2}$'
            and o.dimension_codes->>'Region' like ('K-' || filter_region_code || '%')
          )
        )
      group by cm.occupation_uri, o.dimension_codes->>'Region', o.period_year
    ),
    regional_occupation_previous as (
      select
        rb.*,
        lag(rb.employed_value) over (
          partition by rb.occupation_uri, rb.region_code
          order by rb.period_year
        ) as previous_value,
        row_number() over (
          partition by rb.occupation_uri, rb.region_code
          order by rb.period_year desc
        ) as recency_rank
      from regional_occupation_base rb
    ),
    regional_occupation_latest as (
      select
        rp.*,
        case
          when rp.previous_value is null or rp.previous_value = 0 then null
          else ((rp.employed_value - rp.previous_value) / rp.previous_value) * 100
        end as percent_change,
        max(rp.employed_value) over () as max_employed_value
      from regional_occupation_previous rp
      where rp.recency_rank = 1
    ),
    regional_ranked as (
      select
        rol.occupation_uri,
        round(
          least(
            100,
            greatest(
              0,
              (
                (coalesce(rol.employed_value / nullif(rol.max_employed_value, 0), 0) * 70)
                + (least(1, greatest(0, (coalesce(rol.percent_change, 0) + 5) / 10)) * 30)
              )
            )
          )::numeric,
          2
        ) as relevance_score,
        jsonb_build_object(
          'region_code', rol.region_code,
          'region_label', rol.region_label,
          'relevance_score', round(
            least(
              100,
              greatest(
                0,
                (
                  (coalesce(rol.employed_value / nullif(rol.max_employed_value, 0), 0) * 70)
                  + (least(1, greatest(0, (coalesce(rol.percent_change, 0) + 5) / 10)) * 30)
                )
              )
            )::numeric,
            2
          ),
          'employed_latest', round(rol.employed_value::numeric, 2),
          'percent_change', round(rol.percent_change::numeric, 2)
        ) as regional_signal,
        row_number() over (
          partition by rol.occupation_uri
          order by
            least(
              100,
              greatest(
                0,
                (
                  (coalesce(rol.employed_value / nullif(rol.max_employed_value, 0), 0) * 70)
                  + (least(1, greatest(0, (coalesce(rol.percent_change, 0) + 5) / 10)) * 30)
                )
              )
            ) desc nulls last,
            rol.employed_value desc nulls last
        ) as region_rank
      from regional_occupation_latest rol
    )
    select
      ms.occupation_uri,
      coalesce(ms.title_no, ms.title_en) as title_no,
      ms.market_signal_score,
      ms.market_signal_level,
      ms.latest_period_year,
      ms.employed_latest_thousands,
      ms.percent_change,
      coalesce(ind.industries, '[]'::jsonb) as industries,
      regional.regional_signal,
      round(
        case
          when regional.relevance_score is null then ms.market_signal_score
          else ((ms.market_signal_score * 0.65) + (regional.relevance_score * 0.35))
        end::numeric,
        2
      ) as direction_score
    from candidate_market ms
    left join industry_labels ind on ind.occupation_uri = ms.occupation_uri
    left join regional_ranked regional
      on regional.occupation_uri = ms.occupation_uri
     and regional.region_rank = 1
    order by
      round(
        case
          when regional.relevance_score is null then ms.market_signal_score
          else ((ms.market_signal_score * 0.65) + (regional.relevance_score * 0.35))
        end::numeric,
        2
      ) desc nulls last,
      ms.market_signal_score desc nulls last,
      ms.employed_latest_thousands desc nulls last
    limit 12
  ) d;

  career_directions := jsonb_build_object(
    'items', coalesce(top_direction, '[]'::jsonb),
    'interpretation', 'Karriereretninger som kombinerer markedssignal, bransjekobling og eventuelt valgt område.'
  );

  competence_areas := jsonb_build_object(
    'from_employer_needs', coalesce((
      select jsonb_agg(signal order by nullif(signal->>'value', '')::numeric desc nulls last)
      from jsonb_array_elements(coalesce(top_need, '[]'::jsonb)) signals(signal)
      where signal->>'type' in ('nho_competence_field_need', 'nho_education_level_need')
    ), '[]'::jsonb),
    'sample_skills', coalesce((
      with top_occupations as (
        select value->>'occupation_uri' as occupation_uri
        from jsonb_array_elements(coalesce(top_direction, '[]'::jsonb)) directions(value)
        limit 20
      ),
      skill_counts as (
        select
          sk.uri,
          sk.title_no,
          count(*) as occupation_count,
          sum(case when os.relation_type = 'essential' then 2 else 1 end) as weight
        from top_occupations top_occ
        join public.esco_occupation_skills os on os.occupation_uri = top_occ.occupation_uri
        join public.esco_entities sk on sk.uri = os.skill_uri
        where sk.entity_type = 'skill'
          and sk.title_no is not null
        group by sk.uri, sk.title_no
      )
      select jsonb_agg(
        jsonb_build_object(
          'uri', uri,
          'label', title_no,
          'occupation_count', occupation_count,
          'weight', weight
        )
        order by weight desc, occupation_count desc, title_no
      )
      from (
        select *
        from skill_counts
        order by weight desc, occupation_count desc, title_no
        limit 12
      ) skills
    ), '[]'::jsonb),
    'interpretation', 'Fagområder fra arbeidsgiverbehov og eksempelkompetanser fra karriereretninger som peker seg ut.'
  );

  suggested_explorations := jsonb_build_array(
    jsonb_build_object(
      'type', 'choose_region',
      'title', 'Gjør bildet mer relevant for ditt område',
      'description', 'Velg et område og se hvilke signaler som endrer seg.',
      'action_label', 'Velg område'
    ),
    jsonb_build_object(
      'type', 'choose_industry',
      'title', 'Utforsk en bransje',
      'description', 'Filtrer på bransje for å se arbeidsgiverbehov og sysselsetting i en tydeligere retning.',
      'action_label', 'Velg bransje'
    ),
    jsonb_build_object(
      'type', 'search_occupation',
      'title', 'Søk etter en stilling',
      'description', 'Få kompetanseprofil, markedssignal og nærliggende karriereveier for en konkret stilling.',
      'action_label', 'Søk stilling'
    )
  );

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'key', source_key,
        'provider', provider,
        'title', title,
        'version', version,
        'imported_at', imported_at,
        'metadata', metadata
      )
      order by provider, source_key
    ),
    '[]'::jsonb
  )
  into data_source_cards
  from public.external_data_sources
  where source_key in ('ssb_labor_market_tables', 'nho_kompetansebarometeret');

  data_source_cards :=
    jsonb_build_array(
      jsonb_build_object(
        'key', 'esco_styrk',
        'provider', 'ESCO/STYRK',
        'title', 'Yrkes- og kompetansedata med norske stillingsbetegnelser',
        'version', 'ESCO v1.2.1 + STYRK-08/EURES mapping',
        'metadata', jsonb_build_object(
          'use', 'Stillingsmatch, typiske kompetanser og nærliggende karriereveier'
        )
      )
    )
    || data_source_cards;

  select coalesce(jsonb_agg(message), '[]'::jsonb)
  into insight_messages
  from (
    values
      (
        case
          when jsonb_array_length(coalesce(top_need, '[]'::jsonb)) > 0
            then 'Arbeidsgiverdataene viser tydelige kompetansebehov som kan utforskes videre.'
          else null
        end
      ),
      (
        case
          when jsonb_array_length(coalesce(top_industry, '[]'::jsonb)) > 0
            then format('Bransjeoversikten viser sysselsetting og utvikling for %s.', lower(scope_title))
          else null
        end
      ),
      (
        case
          when jsonb_array_length(coalesce(top_region, '[]'::jsonb)) > 0
            then format('Områder som %s peker seg ut i datagrunnlaget.', top_region->0->>'region_label')
          else null
        end
      ),
      (
        case
          when jsonb_array_length(coalesce(top_direction, '[]'::jsonb)) > 0
            then 'Du kan gå videre til konkrete stillinger for å se kompetanseprofil og nærliggende karriereveier.'
          else null
        end
      )
  ) messages(message)
  where message is not null;

  return jsonb_build_object(
    'found', true,
    'schema_version', 'public_market_overview.v1',
    'filters', jsonb_build_object(
      'region_code', filter_region_code,
      'region_label', selected_region_label,
      'industry_slug', filter_industry_slug,
      'industry_name', selected_industry.name_no
    ),
    'scope', jsonb_build_object(
      'title', scope_title,
      'region_code', filter_region_code,
      'region_label', selected_region_label,
      'industry_slug', selected_industry.slug,
      'industry_name', selected_industry.name_no,
      'is_filtered', (filter_region_code is not null and length(trim(filter_region_code)) > 0) or selected_industry.slug is not null
    ),
    'summary', jsonb_build_object(
      'title', summary_title,
      'description', 'En samlet oversikt over arbeidsgiverbehov, sysselsetting, bransjer, områder og karriereretninger du kan utforske videre.',
      'key_insights', insight_messages
    ),
    'employer_needs', employer_needs,
    'industry_trends', industry_trends,
    'regional_signals', regional_signals,
    'career_directions', career_directions,
    'competence_areas', competence_areas,
    'suggested_explorations', suggested_explorations,
    'data_sources', data_source_cards,
    'confidence_notes', jsonb_build_array(
      'Oversikten viser indikatorer, ikke fasitsvar eller personlig karriererådgivning.',
      'NHO-data er aggregerte arbeidsgiversvar og kan ikke tolkes som eksakt stillingsmangel.',
      'SSB-data viser sysselsetting og utvikling i brede yrkes-, bransje- og regionkategorier.',
      'For konkrete stillinger bør brukeren søke videre i Karrierekompasset.'
    )
  );
end;
$$;

grant execute on function public.get_public_market_overview(text, text) to anon, authenticated;
