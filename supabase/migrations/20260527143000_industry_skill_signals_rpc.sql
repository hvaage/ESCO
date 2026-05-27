create or replace function public.get_industry_skill_signals(
  filter_industry_slug text default null,
  filter_region_code text default null,
  result_limit integer default 24
)
returns jsonb
language plpgsql
stable
as $$
declare
  selected_industry record;
  selected_region_label text;
  safe_limit integer;
  payload jsonb;
begin
  safe_limit := greatest(5, least(coalesce(result_limit, 24), 50));

  select *
  into selected_industry
  from public.industries i
  where i.slug = filter_industry_slug
  limit 1;

  select coalesce(
    (
      select max(region_label)
      from public.nho_kb_subgroup_mappings
      where region_code = case
        when filter_region_code ~ '^[0-9]{2}$' then filter_region_code
        when filter_region_code ~ '^K-[0-9]{4}$' then substring(filter_region_code from 3 for 2)
        else null
      end
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

  with candidate_base as (
    select
      e.uri as occupation_uri,
      coalesce(e.title_no, e.title_en, e.title) as occupation_title,
      coalesce(max(oi.confidence), 1.0000) as industry_confidence,
      coalesce(ms.market_signal_score, 35) as market_signal_score,
      coalesce(ms.market_signal_level, 'unknown') as market_signal_level,
      ms.latest_period_year,
      ms.employed_latest_thousands,
      ms.absolute_change_thousands,
      ms.percent_change,
      coalesce(
        jsonb_agg(
          distinct jsonb_build_object(
            'slug', oi.industry_slug,
            'name', i.name_no,
            'confidence', oi.confidence
          )
        ) filter (where oi.industry_slug is not null),
        '[]'::jsonb
      ) as industries
    from public.esco_entities e
    left join public.occupation_industries oi on oi.occupation_uri = e.uri
    left join public.industries i on i.slug = oi.industry_slug
    left join public.v_occupation_market_signals ms on ms.occupation_uri = e.uri
    where e.entity_type = 'occupation'
      and (
        filter_industry_slug is null
        or exists (
          select 1
          from public.occupation_industries oi_filter
          where oi_filter.occupation_uri = e.uri
            and oi_filter.industry_slug = filter_industry_slug
        )
      )
    group by
      e.uri, e.title_no, e.title_en, e.title,
      ms.market_signal_score, ms.market_signal_level, ms.latest_period_year,
      ms.employed_latest_thousands, ms.absolute_change_thousands, ms.percent_change
  ),
  regional_occupation_base as (
    select
      c.occupation_uri,
      o.dimension_codes->>'Region' as region_code,
      max(trim(split_part(o.dimension_labels->>'Region', ' - ', 1))) as region_label,
      o.period_year,
      sum(o.value * oi.confidence * ism.confidence) as employed_value
    from candidate_base c
    join public.occupation_industries oi on oi.occupation_uri = c.occupation_uri
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
    group by c.occupation_uri, o.dimension_codes->>'Region', o.period_year
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
        'absolute_change', round((rol.employed_value - coalesce(rol.previous_value, rol.employed_value))::numeric, 2),
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
  ),
  candidate_scored as (
    select
      c.*,
      rr.relevance_score as regional_relevance_score,
      rr.regional_signal,
      round(
        (
          greatest(0.2, c.industry_confidence)
          * (0.55 + (coalesce(c.market_signal_score, 35) / 100))
          * case
              when filter_region_code is null or length(trim(filter_region_code)) = 0 then 1.00
              else (0.70 + (coalesce(rr.relevance_score, 20) / 100))
            end
        )::numeric,
        4
      ) as occupation_weight
    from candidate_base c
    left join regional_ranked rr
      on rr.occupation_uri = c.occupation_uri
     and rr.region_rank = 1
  ),
  totals as (
    select count(*)::numeric as total_occupations
    from candidate_scored
  ),
  skill_rows as (
    select
      os.skill_uri,
      coalesce(sk.title_no, sk.title_en, sk.title) as skill_label,
      os.relation_type,
      c.occupation_uri,
      c.occupation_title,
      c.industries,
      c.market_signal_score,
      c.market_signal_level,
      c.regional_relevance_score,
      c.regional_signal,
      c.occupation_weight,
      case when os.relation_type = 'essential' then 2.0 else 1.0 end as relation_weight
    from candidate_scored c
    join public.esco_occupation_skills os on os.occupation_uri = c.occupation_uri
    join public.esco_entities sk on sk.uri = os.skill_uri
    where sk.entity_type = 'skill'
      and coalesce(sk.title_no, sk.title_en, sk.title) is not null
  ),
  skill_aggregates as (
    select
      sr.skill_uri,
      sr.skill_label,
      count(distinct sr.occupation_uri) as occupation_count,
      count(distinct sr.occupation_uri) filter (where sr.relation_type = 'essential') as essential_occupation_count,
      count(distinct sr.occupation_uri) filter (where sr.relation_type = 'optional') as optional_occupation_count,
      round((count(distinct sr.occupation_uri)::numeric / nullif(max(t.total_occupations), 0) * 100)::numeric, 2) as coverage_percent,
      round(sum(sr.occupation_weight * sr.relation_weight)::numeric, 2) as weighted_score,
      round(sum(sr.occupation_weight * sr.relation_weight) filter (where sr.relation_type = 'essential')::numeric, 2) as essential_weighted_score,
      round(sum(sr.occupation_weight * sr.relation_weight) filter (where sr.relation_type = 'optional')::numeric, 2) as optional_weighted_score,
      round(avg(sr.market_signal_score)::numeric, 2) as average_market_signal_score,
      round(avg(sr.regional_relevance_score)::numeric, 2) as average_regional_signal_score,
      max(t.total_occupations)::integer as total_occupations
    from skill_rows sr
    cross join totals t
    group by sr.skill_uri, sr.skill_label
  ),
  skill_items as (
    select
      sa.*,
      jsonb_build_object(
        'skill_uri', sa.skill_uri,
        'label', sa.skill_label,
        'occupation_count', sa.occupation_count,
        'total_occupations', sa.total_occupations,
        'coverage_percent', sa.coverage_percent,
        'essential_occupation_count', sa.essential_occupation_count,
        'optional_occupation_count', sa.optional_occupation_count,
        'weighted_score', sa.weighted_score,
        'essential_weighted_score', coalesce(sa.essential_weighted_score, 0),
        'optional_weighted_score', coalesce(sa.optional_weighted_score, 0),
        'average_market_signal_score', sa.average_market_signal_score,
        'average_regional_signal_score', sa.average_regional_signal_score,
        'example_occupations', '[]'::jsonb,
        'source', 'ESCO/STYRK yrke-kompetanse-koblinger'
      ) as item
    from skill_aggregates sa
  )
  select jsonb_build_object(
    'found', coalesce((select total_occupations > 0 from totals), false),
    'schema_version', 'industry_skill_signals.v1',
    'filters', jsonb_build_object(
      'industry_slug', filter_industry_slug,
      'industry_name', selected_industry.name_no,
      'region_code', filter_region_code,
      'region_label', selected_region_label
    ),
    'summary', jsonb_build_object(
      'title', case
        when coalesce((select total_occupations from totals), 0) = 0
          then 'Ingen kompetansekrav funnet i valgt utvalg'
        when selected_industry.slug is not null and selected_region_label is not null
          then 'Kompetansekrav i ' || selected_industry.name_no || ' i ' || selected_region_label
        when selected_industry.slug is not null
          then 'Kompetansekrav i ' || selected_industry.name_no
        when selected_region_label is not null
          then 'Kompetansekrav i ' || selected_region_label
        else 'Kompetansekrav på tvers av bransjer'
      end,
      'description', 'Kompetanser koblet til yrker/stillinger i ESCO/STYRK-grunnlaget, vektet med bransje og markedssignal der datagrunnlaget støtter det.',
      'total_occupations', coalesce((select total_occupations::integer from totals), 0),
      'total_skills', coalesce((select count(*) from skill_aggregates), 0)
    ),
    'common_requirements', coalesce((
      select jsonb_agg(enriched_item order by weighted_score desc nulls last, occupation_count desc, skill_label)
      from (
        select
          base.*,
          base.item || jsonb_build_object('example_occupations', coalesce(examples.example_occupations, '[]'::jsonb)) as enriched_item
        from (
          select *
          from skill_items
          order by weighted_score desc nulls last, occupation_count desc, skill_label
          limit safe_limit
        ) base
        left join lateral (
          select jsonb_agg(
            jsonb_build_object(
              'occupation_uri', x.occupation_uri,
              'title', x.occupation_title,
              'relation_type', x.relation_type,
              'market_signal_score', x.market_signal_score,
              'market_signal_level', x.market_signal_level,
              'regional_signal', x.regional_signal,
              'industries', x.industries
            )
            order by x.relation_sort, x.occupation_weight desc, x.market_signal_score desc nulls last, x.occupation_title
          ) as example_occupations
          from (
            select
              sr.*,
              case when sr.relation_type = 'essential' then 0 else 1 end as relation_sort,
              row_number() over (
                partition by sr.occupation_uri
                order by case when sr.relation_type = 'essential' then 0 else 1 end
              ) as occupation_relation_rank
            from skill_rows sr
            where sr.skill_uri = base.skill_uri
            order by
              case when sr.relation_type = 'essential' then 0 else 1 end,
              sr.occupation_weight desc,
              sr.market_signal_score desc nulls last,
              sr.occupation_title
            limit 8
          ) x
          where x.occupation_relation_rank = 1
        ) examples on true
        order by weighted_score desc nulls last, occupation_count desc, skill_label
      ) x
    ), '[]'::jsonb),
    'less_common_requirements', coalesce((
      select jsonb_agg(enriched_item order by coverage_percent asc nulls last, weighted_score desc nulls last, skill_label)
      from (
        select
          base.*,
          base.item || jsonb_build_object('example_occupations', coalesce(examples.example_occupations, '[]'::jsonb)) as enriched_item
        from (
          select *
          from skill_items
          where occupation_count >= case when total_occupations >= 15 then 2 else 1 end
          order by coverage_percent asc nulls last, weighted_score desc nulls last, skill_label
          limit safe_limit
        ) base
        left join lateral (
          select jsonb_agg(
            jsonb_build_object(
              'occupation_uri', x.occupation_uri,
              'title', x.occupation_title,
              'relation_type', x.relation_type,
              'market_signal_score', x.market_signal_score,
              'market_signal_level', x.market_signal_level,
              'regional_signal', x.regional_signal,
              'industries', x.industries
            )
            order by x.relation_sort, x.occupation_weight desc, x.market_signal_score desc nulls last, x.occupation_title
          ) as example_occupations
          from (
            select
              sr.*,
              case when sr.relation_type = 'essential' then 0 else 1 end as relation_sort,
              row_number() over (
                partition by sr.occupation_uri
                order by case when sr.relation_type = 'essential' then 0 else 1 end
              ) as occupation_relation_rank
            from skill_rows sr
            where sr.skill_uri = base.skill_uri
            order by
              case when sr.relation_type = 'essential' then 0 else 1 end,
              sr.occupation_weight desc,
              sr.market_signal_score desc nulls last,
              sr.occupation_title
            limit 8
          ) x
          where x.occupation_relation_rank = 1
        ) examples on true
        order by coverage_percent asc nulls last, weighted_score desc nulls last, skill_label
      ) x
    ), '[]'::jsonb),
    'essential_requirements', coalesce((
      select jsonb_agg(enriched_item order by essential_weighted_score desc nulls last, essential_occupation_count desc, skill_label)
      from (
        select
          base.*,
          base.item || jsonb_build_object('example_occupations', coalesce(examples.example_occupations, '[]'::jsonb)) as enriched_item
        from (
          select *
          from skill_items
          where essential_occupation_count > 0
          order by essential_weighted_score desc nulls last, essential_occupation_count desc, skill_label
          limit safe_limit
        ) base
        left join lateral (
          select jsonb_agg(
            jsonb_build_object(
              'occupation_uri', x.occupation_uri,
              'title', x.occupation_title,
              'relation_type', x.relation_type,
              'market_signal_score', x.market_signal_score,
              'market_signal_level', x.market_signal_level,
              'regional_signal', x.regional_signal,
              'industries', x.industries
            )
            order by x.relation_sort, x.occupation_weight desc, x.market_signal_score desc nulls last, x.occupation_title
          ) as example_occupations
          from (
            select
              sr.*,
              case when sr.relation_type = 'essential' then 0 else 1 end as relation_sort,
              row_number() over (
                partition by sr.occupation_uri
                order by case when sr.relation_type = 'essential' then 0 else 1 end
              ) as occupation_relation_rank
            from skill_rows sr
            where sr.skill_uri = base.skill_uri
            order by
              case when sr.relation_type = 'essential' then 0 else 1 end,
              sr.occupation_weight desc,
              sr.market_signal_score desc nulls last,
              sr.occupation_title
            limit 8
          ) x
          where x.occupation_relation_rank = 1
        ) examples on true
        order by essential_weighted_score desc nulls last, essential_occupation_count desc, skill_label
      ) x
    ), '[]'::jsonb),
    'optional_requirements', coalesce((
      select jsonb_agg(enriched_item order by optional_weighted_score desc nulls last, optional_occupation_count desc, skill_label)
      from (
        select
          base.*,
          base.item || jsonb_build_object('example_occupations', coalesce(examples.example_occupations, '[]'::jsonb)) as enriched_item
        from (
          select *
          from skill_items
          where optional_occupation_count > 0
          order by optional_weighted_score desc nulls last, optional_occupation_count desc, skill_label
          limit safe_limit
        ) base
        left join lateral (
          select jsonb_agg(
            jsonb_build_object(
              'occupation_uri', x.occupation_uri,
              'title', x.occupation_title,
              'relation_type', x.relation_type,
              'market_signal_score', x.market_signal_score,
              'market_signal_level', x.market_signal_level,
              'regional_signal', x.regional_signal,
              'industries', x.industries
            )
            order by x.relation_sort, x.occupation_weight desc, x.market_signal_score desc nulls last, x.occupation_title
          ) as example_occupations
          from (
            select
              sr.*,
              case when sr.relation_type = 'essential' then 0 else 1 end as relation_sort,
              row_number() over (
                partition by sr.occupation_uri
                order by case when sr.relation_type = 'essential' then 0 else 1 end
              ) as occupation_relation_rank
            from skill_rows sr
            where sr.skill_uri = base.skill_uri
            order by
              case when sr.relation_type = 'essential' then 0 else 1 end,
              sr.occupation_weight desc,
              sr.market_signal_score desc nulls last,
              sr.occupation_title
            limit 8
          ) x
          where x.occupation_relation_rank = 1
        ) examples on true
        order by optional_weighted_score desc nulls last, optional_occupation_count desc, skill_label
      ) x
    ), '[]'::jsonb),
    'data_sources', jsonb_build_array(
      jsonb_build_object(
        'provider', 'ESCO/STYRK',
        'title', 'Yrke-kompetanse-koblinger med norske stillingsbetegnelser'
      ),
      jsonb_build_object(
        'provider', 'Statistisk sentralbyrå',
        'title', 'Markedssignal brukt til vekting der relevant'
      )
    ),
    'confidence_notes', jsonb_build_array(
      'Dette er ikke telling av stillingsannonser, men kompetanser knyttet til ESCO/STYRK-yrker.',
      'Mindre vanlige kompetansekrav kan være spesialiserte krav, ikke uviktige krav.',
      'Regionfilter brukes som markedssignal/proxy der datagrunnlaget støtter det.'
    )
  )
  into payload;

  return payload;
end;
$$;

grant execute on function public.get_industry_skill_signals(text, text, integer) to anon, authenticated;
