--add PGS codes to measurement table

-------------------------------------------------------------------------------------------------------------------------------
SET SEARCH_PATH to :ohdsi;

--insert PGS score values
INSERT INTO measurement
(--measurement_id,
    person_id,
    measurement_concept_id,
    measurement_date,
    measurement_datetime,
    --measurement_time, --The time of the Measurement. This is present for backwards compatibility and will be deprecated in an upcoming version
    measurement_type_concept_id,
    operator_concept_id,
    value_as_number,
    --value_as_concept_id,
    --unit_concept_id,
    --range_low,
    --range_high,
    --provider_id,
    --visit_occurrence_id,
    --visit_detail_id,
    measurement_source_value, --The Measurement name as it appears in the source data
    measurement_source_concept_id,
    --unit_source_value,
    --unit_source_concept_id,
    value_source_value
    --measurement_event_id,
    --meas_event_field_id,
    )
SELECT DISTINCT
       pe.person_id                                                 as person_id,
       map.target_concept_id                                        as measurement_concept_id,
       GREATEST(:observation_time_start, pe.birth_datetime::date)   as measurement_date, --basically the observation_period_start_date
       GREATEST(:observation_time_start, pe.birth_datetime::date)   as measurement_datetime, --basically the observation_period_start_date
       32880                                                        as measurement_type_concept_id, --	Standard algorithm
       4172703                                                      as operator_concept_id, --4172703 refers to "="
       pm.pgs_score::numeric                                        as value_as_number,
       pm.measurement_source_value                                  as measurement_source_value,
       map.source_concept_id                                        as measurement_source_concept_id,
       pm.pgs_score                                                 as value_source_value
FROM
	:pgs_calculations.prs_measurement pm
INNER JOIN --add the person_id from the person table, because we need to have the person in the OHDSI model to be able to add the measurement
    person pe ON
    pm.patient_id = pe.person_source_value
LEFT JOIN --add the concept_id for the measurement_source_value from the source_to_concept_map table, so that we can have the correct concept_id in the measurement table
    (SELECT * FROM source_to_concept_map WHERE est_source_code_type = 'pgs_score')  map ON
	pm.measurement_source_value = map.source_code
WHERE
	pm.measurement_source_value IS NOT NULL
    AND pm.pgs_score IS NOT NULL
;


--insert PGS score percentile values
INSERT INTO measurement
(--measurement_id,
    person_id,
    measurement_concept_id,
    measurement_date,
    measurement_datetime,
    --measurement_time, --The time of the Measurement. This is present for backwards compatibility and will be deprecated in an upcoming version
    measurement_type_concept_id,
    --operator_concept_id,
    value_as_number,
    --value_as_concept_id,
    --unit_concept_id,
    --range_low,
    --range_high,
    --provider_id,
    --visit_occurrence_id,
    --visit_detail_id,
    measurement_source_value, --The Measurement name as it appears in the source data
    measurement_source_concept_id,
    --unit_source_value,
    --unit_source_concept_id,
    value_source_value
    --measurement_event_id,
    --meas_event_field_id
    )
SELECT DISTINCT
       pe.person_id                                                 as person_id,
       map.target_concept_id                                        as measurement_concept_id,
       GREATEST(:observation_time_start, pe.birth_datetime::date)   as measurement_date,
       GREATEST(:observation_time_start, pe.birth_datetime::date)   as measurement_datetime,
       32880                                                        as measurement_type_concept_id, --	Standard algorithm
       pm.pgs_score_percentile::numeric                             as value_as_number,
       pm.measurement_source_value                                  as measurement_source_value,
       map.source_concept_id                                        as measurement_source_concept_id,
       pm.pgs_score_percentile                                      as value_source_value
FROM
	:pgs_calculations.prs_measurement pm
INNER JOIN --inner join, sest meid ei huvita isikud, keda OHDSI mudelisse ei kantud
    person pe ON
    pm.patient_id = pe.person_source_value
LEFT JOIN
    (SELECT * FROM source_to_concept_map WHERE est_source_code_type = 'pgs_score_percentile')  map ON
	pm.measurement_source_value = map.source_code
WHERE
	pm.measurement_source_value IS NOT NULL
    AND pm.pgs_score_percentile IS NOT NULL
;



