create or replace function public.get_career_direction_explorer(
  search_text text,
  filter_region_code text default null,
  filter_industry_slug text default null
)
returns jsonb
language plpgsql
stable
as $$
declare
  compass jsonb;
  market jsonb;
  occupation jsonb;
  market_score numeric;
  search_score numeric;
  nho_unmet_score numeric;
  nho_competence_score numeric;
  overall_score numeric;
  overall_level text;
  overall_label_no text;
  essential_count integer;
  optional_count integer;
  essential_skills jsonb;
  optional_skills jsonb;
  learn_start jsonb;
  learn_then jsonb;
  industry_cards jsonb;
  industry_signal_cards jsonb;
  region_cards jsonb;
  related_cards jsonb;
  opportunity_matrix jsonb;
  employer_signals jsonb;
  competence_field_signals jsonb;
  demand_bars jsonb;
  insight_messages jsonb;
  data_source_cards jsonb;
  top_region jsonb;
  top_industry jsonb;
  compass_region_filter text;
begin
  compass_region_filter := case
    when filter_region_code like 'K-%' then null
    else filter_region_code
  end;

  compass := public.get_public_career_compass(search_text, compass_region_filter, filter_industry_slug);

  if not coalesce((compass->>'found')::boolean, false) then
    return jsonb_build_object(
      'found', false,
      'schema_version', 'career_direction_explorer.v1',
      'query', search_text,
      'filters', jsonb_build_object(
        'region_code', filter_region_code,
        'industry_slug', filter_industry_slug
      ),
      'message', coalesce(compass->>'message', 'Fant ikke yrke/stilling i ESCO/STYRK-grunnlaget.'),
      'empty_state', jsonb_build_object(
        'title', 'Fant ikke en trygg match',
        'suggestion', 'Prøv en norsk stillingstittel, for eksempel sykepleier, elektriker eller programvareutvikler.'
      )
    );
  end if;

  market := coalesce(compass->'market_signal', '{}'::jsonb);
  occupation := coalesce(compass->'occupation', '{}'::jsonb);

  if occupation ? 'search_score' then
    search_score := nullif(occupation->>'search_score', '')::numeric;
  end if;

  if search_score is not null and search_score < 0.3000 then
    return jsonb_build_object(
      'found', false,
      'schema_version', 'career_direction_explorer.v1',
      'query', search_text,
      'filters', jsonb_build_object(
        'region_code', filter_region_code,
        'industry_slug', filter_industry_slug
      ),
      'message', 'Fant ikke en trygg nok match for søket.',
      'candidate_match', jsonb_build_object(
        'title', coalesce(occupation->>'title_no', occupation->>'title_en', occupation->>'title'),
        'search_score', search_score
      ),
      'empty_state', jsonb_build_object(
        'title', 'Fant ikke en trygg match',
        'suggestion', 'Prøv en mer konkret norsk stillingstittel, for eksempel sykepleier, elektriker eller programvareutvikler.'
      )
    );
  end if;

  if market ? 'market_signal_score' then
    market_score := nullif(market->>'market_signal_score', '')::numeric;
  end if;

  select max(nullif(signal->>'signal_value', '')::numeric)
  into nho_unmet_score
  from jsonb_array_elements(coalesce(compass->'nho_signals', '[]'::jsonb)) as signals(signal)
  where signal->>'signal_type' = 'nho_unmet_need';

  select max(nullif(signal->>'signal_value', '')::numeric)
  into nho_competence_score
  from jsonb_array_elements(coalesce(compass->'nho_signals', '[]'::jsonb)) as signals(signal)
  where signal->>'signal_type' in ('nho_competence_field_need', 'nho_education_level_need');

  if market_score is not null and nho_unmet_score is not null then
    overall_score := round(((market_score * 0.65) + (nho_unmet_score * 0.35))::numeric, 2);
  elsif market_score is not null then
    overall_score := round(market_score, 2);
  elsif nho_unmet_score is not null then
    overall_score := round(nho_unmet_score, 2);
  end if;

  overall_level := case
    when overall_score is null then 'unknown'
    when overall_score >= 70 then 'high'
    when overall_score >= 40 then 'medium'
    else 'low'
  end;

  overall_label_no := case overall_level
    when 'high' then 'Sterkt signal'
    when 'medium' then 'Moderat signal'
    when 'low' then 'Svakt signal'
    else 'Ukjent signal'
  end;

  essential_count := jsonb_array_length(coalesce(compass #> '{skills,essential}', '[]'::jsonb));
  optional_count := jsonb_array_length(coalesce(compass #> '{skills,optional}', '[]'::jsonb));

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'uri', skill->>'uri',
        'label', coalesce(skill->>'title_no', skill->>'title_en'),
        'skill_type', skill->>'skill_type',
        'priority', position,
        'reason', 'Nødvendig kompetanse i ESCO for valgt yrke'
      )
      order by position
    ),
    '[]'::jsonb
  )
  into essential_skills
  from (
    select skill, position
    from jsonb_array_elements(coalesce(compass #> '{skills,essential}', '[]'::jsonb))
      with ordinality as items(skill, position)
    limit 12
  ) ranked;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'uri', skill->>'uri',
        'label', coalesce(skill->>'title_no', skill->>'title_en'),
        'skill_type', skill->>'skill_type',
        'priority', position,
        'reason', 'Tilleggskompetanse i ESCO som kan styrke profilen'
      )
      order by position
    ),
    '[]'::jsonb
  )
  into optional_skills
  from (
    select skill, position
    from jsonb_array_elements(coalesce(compass #> '{skills,optional}', '[]'::jsonb))
      with ordinality as items(skill, position)
    limit 12
  ) ranked;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'uri', skill->>'uri',
        'label', skill->>'title_no'
      )
      order by position
    ),
    '[]'::jsonb
  )
  into learn_start
  from (
    select skill, position
    from jsonb_array_elements(coalesce(compass #> '{learn_next,start_with}', '[]'::jsonb))
      with ordinality as items(skill, position)
    limit 8
  ) ranked;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'uri', skill->>'uri',
        'label', skill->>'title_no'
      )
      order by position
    ),
    '[]'::jsonb
  )
  into learn_then
  from (
    select skill, position
    from jsonb_array_elements(coalesce(compass #> '{learn_next,then_consider}', '[]'::jsonb))
      with ordinality as items(skill, position)
    limit 8
  ) ranked;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'slug', industry->>'slug',
        'name', industry->>'name_no',
        'confidence', nullif(industry->>'confidence', '')::numeric,
        'source', industry->>'source'
      )
      order by nullif(industry->>'confidence', '')::numeric desc nulls last, industry->>'name_no'
    ),
    '[]'::jsonb
  )
  into industry_cards
  from jsonb_array_elements(coalesce(compass->'industries', '[]'::jsonb)) as industries(industry);

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'name', signal->>'industry_name_no',
        'latest_year', signal->>'latest_period_year',
        'employed_latest', signal->>'employed_latest',
        'absolute_change', signal->>'absolute_change',
        'percent_change', signal->>'percent_change',
        'mapping_confidence', signal->>'mapping_confidence'
      )
      order by nullif(signal->>'employed_latest', '')::numeric desc nulls last
    ),
    '[]'::jsonb
  )
  into industry_signal_cards
  from jsonb_array_elements(coalesce(compass->'industry_signals', '[]'::jsonb)) as signals(signal);

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'region_code', regional.region_code,
        'region_label', regional.region_label,
        'latest_year', regional.latest_period_year,
        'relevance_score', regional.relevance_score,
        'employed_latest', regional.employed_latest,
        'absolute_change', regional.absolute_change,
        'percent_change', regional.percent_change,
        'mapping_confidence', regional.mapping_confidence
      )
      order by regional.relevance_score desc nulls last, regional.employed_latest desc nulls last
    ),
    '[]'::jsonb
  )
  into region_cards
  from (
    select *
    from public.v_occupation_regional_signals rs
    where rs.occupation_uri = occupation->>'uri'
      and (
        filter_region_code is null
        or length(trim(filter_region_code)) = 0
        or rs.region_code = filter_region_code
        or (
          filter_region_code ~ '^[0-9]{2}$'
          and rs.region_code like ('K-' || filter_region_code || '%')
        )
      )
    order by rs.relevance_score desc nulls last, rs.employed_latest desc nulls last
    limit case
      when filter_region_code is null or length(trim(filter_region_code)) = 0 then 10
      else 25
    end
  ) regional;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'occupation_uri', opportunity.occupation_uri,
        'title', opportunity.title,
        'overlap_count', opportunity.overlap_count,
        'overlap_score', opportunity.overlap_score,
        'overlap_index', opportunity.overlap_score,
        'market_signal_score', opportunity.market_signal_score,
        'market_signal_level', opportunity.market_signal_level,
        'opportunity_score', opportunity.opportunity_score,
        'opportunity_level', opportunity.opportunity_level,
        'quadrant', opportunity.quadrant,
        'quadrant_label', opportunity.quadrant_label,
        'industry_names', opportunity.industry_names,
        'shared_skills', opportunity.shared_skills,
        'market_signal', opportunity.market_signal,
        'regional_signal', opportunity.regional_signal,
        'matrix', jsonb_build_object(
          'x', opportunity.market_signal_score,
          'y', least(opportunity.overlap_score, 100),
          'x_label', 'Markedssignal',
          'y_label', 'Kompetanseoverlapp',
          'size', opportunity.overlap_count
        )
      )
      order by opportunity.opportunity_score desc nulls last,
               opportunity.overlap_score desc nulls last,
               opportunity.overlap_count desc nulls last
    ),
    '[]'::jsonb
  )
  into related_cards
  from (
    select
      related->>'occupation_uri' as occupation_uri,
      coalesce(related->>'title_no', related->>'title_en') as title,
      nullif(related->>'overlap_count', '')::integer as overlap_count,
      nullif(related->>'overlap_score', '')::numeric as overlap_score,
      ms.market_signal_score,
      ms.market_signal_level,
      round(
        case
          when ms.market_signal_score is null then least(nullif(related->>'overlap_score', '')::numeric, 100)
          else (
            (least(nullif(related->>'overlap_score', '')::numeric, 100) * 0.55)
            + (ms.market_signal_score * 0.45)
          )
        end::numeric,
        2
      ) as opportunity_score,
      case
        when ms.market_signal_score is null then 'unknown'
        when (
          (least(nullif(related->>'overlap_score', '')::numeric, 100) * 0.55)
          + (ms.market_signal_score * 0.45)
        ) >= 70 then 'high'
        when (
          (least(nullif(related->>'overlap_score', '')::numeric, 100) * 0.55)
          + (ms.market_signal_score * 0.45)
        ) >= 40 then 'medium'
        else 'low'
      end as opportunity_level,
      case
        when ms.market_signal_score is null then 'missing_market_signal'
        when nullif(related->>'overlap_score', '')::numeric >= 60 and ms.market_signal_score >= 60 then 'near_and_strong'
        when nullif(related->>'overlap_score', '')::numeric < 60 and ms.market_signal_score >= 60 then 'strong_but_requires_lift'
        when nullif(related->>'overlap_score', '')::numeric >= 60 and ms.market_signal_score < 60 then 'near_transition'
        else 'explore_with_caution'
      end as quadrant,
      case
        when ms.market_signal_score is null then 'Mangler markedssignal'
        when nullif(related->>'overlap_score', '')::numeric >= 60 and ms.market_signal_score >= 60 then 'Nært og attraktivt'
        when nullif(related->>'overlap_score', '')::numeric < 60 and ms.market_signal_score >= 60 then 'Sterkt signal, krever kompetanseløft'
        when nullif(related->>'overlap_score', '')::numeric >= 60 and ms.market_signal_score < 60 then 'Nær overgang'
        else 'Verdt å undersøke'
      end as quadrant_label,
      coalesce(related->'industry_names', '[]'::jsonb) as industry_names,
      coalesce(related->'shared_skills', '[]'::jsonb) as shared_skills,
      case
        when ms.occupation_uri is null then '{}'::jsonb
        else jsonb_build_object(
          'score', ms.market_signal_score,
          'level', ms.market_signal_level,
          'latest_year', ms.latest_period_year,
          'employed_latest', ms.employed_latest_thousands,
          'percent_change', ms.percent_change,
          'source', 'Statistisk sentralbyrå'
        )
      end as market_signal,
      case
        when regional.region_code is null then null
        else jsonb_build_object(
          'region_code', regional.region_code,
          'region_label', regional.region_label,
          'relevance_score', regional.relevance_score,
          'employed_latest', regional.employed_latest,
          'percent_change', regional.percent_change,
          'latest_year', regional.latest_period_year
        )
      end as regional_signal
    from jsonb_array_elements(coalesce(compass->'related_occupations', '[]'::jsonb)) as related_items(related)
    left join public.v_occupation_market_signals ms
      on ms.occupation_uri = related->>'occupation_uri'
    left join lateral (
      select *
      from public.v_occupation_regional_signals rs
      where rs.occupation_uri = related->>'occupation_uri'
        and (
          filter_region_code is null
          or length(trim(filter_region_code)) = 0
          or rs.region_code = filter_region_code
          or (
            filter_region_code ~ '^[0-9]{2}$'
            and rs.region_code like ('K-' || filter_region_code || '%')
          )
        )
      order by rs.relevance_score desc nulls last, rs.employed_latest desc nulls last
      limit 1
    ) regional on true
    where (
      filter_industry_slug is null
      or length(trim(filter_industry_slug)) = 0
      or exists (
        select 1
        from public.occupation_industries oi
        where oi.occupation_uri = related->>'occupation_uri'
          and oi.industry_slug = filter_industry_slug
      )
    )
  ) opportunity;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'type', signal->>'signal_type',
        'label', signal->>'signal_label',
        'value', nullif(signal->>'signal_value', '')::numeric,
        'high_intensity_value', nullif(signal->>'high_intensity_value', '')::numeric,
        'year', nullif(signal->>'period', '')::integer,
        'scope', coalesce(signal->>'industry_name_no', signal->>'region_label', 'Nasjonalt'),
        'group_type', signal->>'group_type',
        'sample_base', signal->>'sample_base',
        'confidence', signal->>'confidence'
      )
      order by position
    ),
    '[]'::jsonb
  )
  into employer_signals
  from (
    select signal, position
    from jsonb_array_elements(coalesce(compass->'nho_signals', '[]'::jsonb))
      with ordinality as items(signal, position)
    limit 10
  ) ranked;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'label', signal->>'signal_label',
        'value', nullif(signal->>'signal_value', '')::numeric,
        'year', nullif(signal->>'period', '')::integer,
        'scope', coalesce(signal->>'industry_name_no', signal->>'region_label', 'Nasjonalt')
      )
      order by nullif(signal->>'signal_value', '')::numeric desc nulls last
    ),
    '[]'::jsonb
  )
  into competence_field_signals
  from (
    select signal
    from jsonb_array_elements(coalesce(compass->'nho_signals', '[]'::jsonb)) as signals(signal)
    where signal->>'signal_type' in ('nho_competence_field_need', 'nho_education_level_need')
    order by nullif(signal->>'signal_value', '')::numeric desc nulls last
    limit 8
  ) ranked;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'key', bar_key,
        'label', label,
        'value', round(value, 2),
        'level', case
          when value >= 70 then 'high'
          when value >= 40 then 'medium'
          else 'low'
        end,
        'source', source,
        'description', description
      )
      order by sort_order
    ),
    '[]'::jsonb
  )
  into demand_bars
  from (
    values
      (1, 'ssb_occupation_market', 'Sysselsetting i yrket', market_score, 'Statistisk sentralbyrå', 'Utvikling i sysselsetting for relevante yrker.'),
      (2, 'nho_unmet_need', 'Arbeidsgiveres kompetansebehov', nho_unmet_score, 'NHO Kompetansebarometeret', 'Andel arbeidsgivere som melder udekket kompetansebehov i relevante bransjer eller områder.'),
      (3, 'nho_competence_need', 'Etterspurte kompetanseområder', nho_competence_score, 'NHO Kompetansebarometeret', 'Fagområder og utdanningsnivåer arbeidsgivere oppgir behov for.')
  ) bars(sort_order, bar_key, label, value, source, description)
  where value is not null;

  top_region := region_cards->0;
  top_industry := industry_cards->0;

  opportunity_matrix := jsonb_build_object(
    'title', 'Mulighetsmatrise',
    'description', 'Kombinerer kompetanseoverlapp med markedssignal for nærliggende yrker.',
    'x_axis', jsonb_build_object(
      'key', 'market_signal_score',
      'label', 'Markedssignal',
      'min', 0,
      'max', 100
    ),
    'y_axis', jsonb_build_object(
      'key', 'overlap_index',
      'label', 'Kompetanseoverlapp',
      'min', 0,
      'max', 100,
      'note', 'Overlappindeks normaliseres til 100 i visualisering, men rå indeks beholdes i kortene.'
    ),
    'quadrants', jsonb_build_array(
      jsonb_build_object('key', 'near_and_strong', 'label', 'Nært og attraktivt', 'description', 'Høy kompetanseoverlapp og sterkt markedssignal.'),
      jsonb_build_object('key', 'strong_but_requires_lift', 'label', 'Sterkt signal, krever kompetanseløft', 'description', 'Sterkt markedssignal, men lavere kompetanseoverlapp.'),
      jsonb_build_object('key', 'near_transition', 'label', 'Nær overgang', 'description', 'Høy kompetanseoverlapp, men svakere markedssignal.'),
      jsonb_build_object('key', 'explore_with_caution', 'label', 'Verdt å undersøke', 'description', 'Lavere signal eller lavere overlapp i datagrunnlaget.'),
      jsonb_build_object('key', 'missing_market_signal', 'label', 'Mangler markedssignal', 'description', 'Yrket mangler nok markedssignal til å plasseres trygt.')
    ),
    'items', related_cards
  );

  select coalesce(jsonb_agg(message), '[]'::jsonb)
  into insight_messages
  from (
    values
      (
        case
          when overall_score is not null
            then format(
              'Markedssignalet er %s. Det bygger på sysselsettingsdata og arbeidsgiveres rapporterte kompetansebehov.',
              case overall_level
                when 'high' then 'sterkt'
                when 'medium' then 'moderat'
                when 'low' then 'svakt'
                else 'ukjent'
              end
            )
          else null
        end
      ),
      (
        case
          when essential_count > 0
            then format('Vi fant %s typiske må-ha-kompetanser og %s kompetanser som kan styrke profilen.', essential_count, optional_count)
          else null
        end
      ),
      (
        case
          when top_region is not null
            then format('Blant områdene i datagrunnlaget peker %s tydeligst ut for denne retningen.', trim(split_part(top_region->>'region_label', ' - ', 1)))
          else null
        end
      ),
      (
        case
          when jsonb_array_length(related_cards) > 0
            then 'Det finnes nærliggende yrker med høy kompetanseoverlapp.'
          else null
        end
      )
  ) messages(message)
  where message is not null;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'key', source_key,
        'provider', provider,
        'name', case source_key
          when 'nho_kompetansebarometeret' then 'NHO Kompetansebarometeret'
          when 'ssb_labor_market_tables' then 'Statistisk sentralbyrå'
          when 'nav_business_survey' then 'NAV Bedriftsundersøkelsen'
          when 'nav_unemployment_monthly' then 'NAV helt ledige'
          when 'nav_vacancies_monthly' then 'NAV ledige stillinger'
          else title
        end,
        'title', case source_key
          when 'nho_kompetansebarometeret' then 'NHO Kompetansebarometeret'
          when 'ssb_labor_market_tables' then 'Statistisk sentralbyrå'
          when 'nav_business_survey' then 'NAV Bedriftsundersøkelsen'
          when 'nav_unemployment_monthly' then 'NAV helt ledige'
          when 'nav_vacancies_monthly' then 'NAV ledige stillinger'
          else title
        end,
        'description', case source_key
          when 'nho_kompetansebarometeret'
            then 'Arbeidsgiveres rapporterte kompetansebehov, fagområder og utdanningsnivåer. Dataene er aggregerte og brukes som signaler.'
          when 'ssb_labor_market_tables'
            then 'Sysselsetting, utvikling, regionale mønstre og lønnsstatistikk fra Statistisk sentralbyrå.'
          when 'nav_business_survey'
            then 'Estimert mangel på arbeidskraft basert på arbeidsgiveres rapporterte rekrutteringsutfordringer.'
          when 'nav_unemployment_monthly'
            then 'Registrerte helt ledige per yrke fra NAVs månedlige statistikk.'
          when 'nav_vacancies_monthly'
            then 'Tilgang ledige stillinger per yrke fra NAVs månedlige statistikk.'
          else coalesce(metadata->>'description', metadata->>'use', provider)
        end,
        'source_url', source_url,
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
  where source_key in (
    'ssb_labor_market_tables',
    'nho_kompetansebarometeret',
    'nav_business_survey',
    'nav_unemployment_monthly',
    'nav_vacancies_monthly'
  );

  data_source_cards :=
    jsonb_build_array(
      jsonb_build_object(
        'key', 'esco_styrk',
        'provider', 'ESCO/STYRK',
        'name', 'Yrkes- og kompetansedata med norske stillingsbetegnelser',
        'title', 'Yrkes- og kompetansedata med norske stillingsbetegnelser',
        'description', 'ESCO gir yrker og kompetanser. STYRK-08/EURES gjør norske stillingstitler lettere å koble til ESCO-yrker.',
        'source_url', 'https://esco.ec.europa.eu/',
        'version', 'ESCO v1.2.1 + STYRK-08/EURES mapping',
        'metadata', jsonb_build_object(
          'use', 'Yrkesmatch, typiske kompetanser, profilbyggende kompetanser og nærliggende yrker'
        )
      )
    )
    || data_source_cards;

  return jsonb_build_object(
    'found', true,
    'schema_version', 'career_direction_explorer.v1',
    'query', search_text,
    'filters', jsonb_build_object(
      'region_code', filter_region_code,
      'industry_slug', filter_industry_slug
    ),
    'summary', jsonb_build_object(
      'title', coalesce(occupation->>'title_no', occupation->>'title_en', occupation->>'title'),
      'description', occupation->>'description_no',
      'search_score', search_score,
      'demand_score', overall_score,
      'demand_level', overall_level,
      'demand_label', overall_label_no,
      'primary_industry', top_industry,
      'key_insights', insight_messages
    ),
    'demand', jsonb_build_object(
      'score', overall_score,
      'level', overall_level,
      'label', overall_label_no,
      'components', demand_bars,
      'market_signal', market,
      'employer_demand', jsonb_build_object(
        'metadata', coalesce(compass->'nho_metadata', '{}'::jsonb),
        'top_unmet_need_score', nho_unmet_score,
        'signals', employer_signals,
        'competence_fields', competence_field_signals
      )
    ),
    'competencies', jsonb_build_object(
      'must_have_count', essential_count,
      'nice_to_have_count', optional_count,
      'must_have', essential_skills,
      'nice_to_have', optional_skills,
      'learn_next', jsonb_build_object(
        'start_with', learn_start,
        'then_consider', learn_then,
        'guidance', 'Start med kompetanser som ofte er sentrale i denne rollen. Bruk tilleggskompetanser til å bygge bredde eller åpne nærliggende karriereveier.'
      )
    ),
    'industries', jsonb_build_object(
      'matches', industry_cards,
      'national_signals', industry_signal_cards
    ),
    'geography', jsonb_build_object(
      'selected_region_code', filter_region_code,
      'filter_type', case
        when filter_region_code like 'K-%' then 'municipality'
        when filter_region_code ~ '^[0-9]{2}$' then 'county_prefix'
        when filter_region_code is not null and length(trim(filter_region_code)) > 0 then 'region_code'
        else null
      end,
      'regions', region_cards
    ),
    'nearby_occupations', related_cards,
    'opportunity_matrix', opportunity_matrix,
    'visualization', jsonb_build_object(
      'demand_bars', demand_bars,
      'skill_counts', jsonb_build_object(
        'must_have', essential_count,
        'nice_to_have', optional_count
      ),
      'region_ranking', region_cards,
      'related_network', related_cards,
      'opportunity_matrix', opportunity_matrix
    ),
    'data_sources', data_source_cards,
    'confidence_notes', jsonb_build_array(
      'SSB-signalet er koblet via STYRK-yrkesgruppe og bransje/fagfelt, ikke som en eksakt ledighetsprediksjon for én stillingstittel.',
      'NHO-data er aggregerte figurdata. Vi kombinerer bare dimensjoner som finnes i publiserte kildedata.',
      'ESCO viser typiske yrkeskompetanser. Faktiske krav i en konkret stillingsannonse kan avvike.'
    )
  );
end;
$$;

grant execute on function public.get_career_direction_explorer(text, text, text) to anon, authenticated;
