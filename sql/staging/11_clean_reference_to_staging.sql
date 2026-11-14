/* ============================================================================
   11_clean_reference_to_staging.sql  -  ETL (T): raw_* reference CSVs -> stg_*

   Part of deliverable "ETL Scripts SQL/Python".

   For each reference source the most recent loaded batch is cleaned:
     - TRIM + collapse whitespace on every text column (fn_clean_text)
     - codes lower-cased (network / magnitude-type codes are matched case-insensitively)
     - names kept in their published casing; blank values -> NULL -> default text
     - duplicate business keys resolved deterministically: LAST row in the file wins
     - UPSERT into stg_* (only rows whose content changed are updated)
   Row counts are written to etl_step_log.
   ============================================================================ */

SET search_path TO project_staging, public;

/* ---- seismic networks ---------------------------------------------------- */
WITH latest AS (
    SELECT max(batch_id) AS b FROM etl_batch
    WHERE source_name = 'ref_seismic_networks' AND status IN ('RAW_LOADED', 'LOADED')
), src AS (
    SELECT DISTINCT ON (lower(fn_clean_text(r.network_code)))
           lower(fn_clean_text(r.network_code))                    AS network_code,
           COALESCE(fn_clean_text(r.network_name), 'Unnamed network') AS network_name,
           fn_clean_text(r.operator)                               AS operator,
           fn_clean_text(r.region_served)                          AS region_served,
           fn_clean_text(r.network_type)                           AS network_type,
           r.batch_id
    FROM raw_seismic_network r JOIN latest ON r.batch_id = latest.b
    WHERE fn_clean_text(r.network_code) IS NOT NULL
    ORDER BY lower(fn_clean_text(r.network_code)), r.source_row_num DESC
), up AS (
    INSERT INTO stg_seismic_network AS t (network_code, network_name, operator, region_served, network_type, source_batch_id)
    SELECT network_code, network_name, operator, region_served, network_type, batch_id FROM src
    ON CONFLICT (network_code) DO UPDATE
       SET network_name = EXCLUDED.network_name, operator = EXCLUDED.operator,
           region_served = EXCLUDED.region_served, network_type = EXCLUDED.network_type,
           source_batch_id = EXCLUDED.source_batch_id, staged_at = now()
     WHERE (t.network_name, t.operator, t.region_served, t.network_type)
           IS DISTINCT FROM (EXCLUDED.network_name, EXCLUDED.operator, EXCLUDED.region_served, EXCLUDED.network_type)
    RETURNING (xmax = 0) AS inserted
)
INSERT INTO etl_step_log (batch_id, step_name, target_table, rows_processed, rows_inserted, rows_updated)
SELECT (SELECT b FROM latest), 'clean_reference', 'project_staging.stg_seismic_network',
       (SELECT count(*) FROM src), count(*) FILTER (WHERE inserted), count(*) FILTER (WHERE NOT inserted)
FROM up
HAVING (SELECT b FROM latest) IS NOT NULL;

/* ---- magnitude types ----------------------------------------------------- */
WITH latest AS (
    SELECT max(batch_id) AS b FROM etl_batch
    WHERE source_name = 'ref_magnitude_types' AND status IN ('RAW_LOADED', 'LOADED')
), src AS (
    SELECT DISTINCT ON (lower(fn_clean_text(r.magnitude_type_code)))
           lower(fn_clean_text(r.magnitude_type_code))                         AS magnitude_type_code,
           COALESCE(fn_clean_text(r.magnitude_type_name), upper(fn_clean_text(r.magnitude_type_code))) AS magnitude_type_name,
           COALESCE(initcap(fn_clean_text(r.scale_family)), 'Other')           AS scale_family,
           fn_clean_text(r.description)                                        AS description,
           r.batch_id
    FROM raw_magnitude_type r JOIN latest ON r.batch_id = latest.b
    WHERE fn_clean_text(r.magnitude_type_code) IS NOT NULL
    ORDER BY lower(fn_clean_text(r.magnitude_type_code)), r.source_row_num DESC
), up AS (
    INSERT INTO stg_magnitude_type AS t (magnitude_type_code, magnitude_type_name, scale_family, description, source_batch_id)
    SELECT magnitude_type_code, magnitude_type_name, scale_family, description, batch_id FROM src
    ON CONFLICT (magnitude_type_code) DO UPDATE
       SET magnitude_type_name = EXCLUDED.magnitude_type_name, scale_family = EXCLUDED.scale_family,
           description = EXCLUDED.description, source_batch_id = EXCLUDED.source_batch_id, staged_at = now()
     WHERE (t.magnitude_type_name, t.scale_family, t.description)
           IS DISTINCT FROM (EXCLUDED.magnitude_type_name, EXCLUDED.scale_family, EXCLUDED.description)
    RETURNING (xmax = 0) AS inserted
)
INSERT INTO etl_step_log (batch_id, step_name, target_table, rows_processed, rows_inserted, rows_updated)
SELECT (SELECT b FROM latest), 'clean_reference', 'project_staging.stg_magnitude_type',
       (SELECT count(*) FROM src), count(*) FILTER (WHERE inserted), count(*) FILTER (WHERE NOT inserted)
FROM up
HAVING (SELECT b FROM latest) IS NOT NULL;

/* ---- US states (used to conform "CA" / "California" -> United States, California) ---- */
WITH latest AS (
    SELECT max(batch_id) AS b FROM etl_batch
    WHERE source_name = 'ref_us_states' AND status IN ('RAW_LOADED', 'LOADED')
), src AS (
    SELECT DISTINCT ON (upper(fn_clean_text(r.state_code)))
           upper(fn_clean_text(r.state_code))                   AS state_code,
           initcap(fn_clean_text(r.state_name))                 AS state_name,
           COALESCE(upper(fn_clean_text(r.match_by_name)), 'Y') = 'Y' AS match_by_name,
           r.batch_id
    FROM raw_us_state r JOIN latest ON r.batch_id = latest.b
    WHERE length(fn_clean_text(r.state_code)) = 2 AND fn_clean_text(r.state_name) IS NOT NULL
    ORDER BY upper(fn_clean_text(r.state_code)), r.source_row_num DESC
), up AS (
    INSERT INTO stg_us_state AS t (state_code, state_name, match_by_name, source_batch_id)
    SELECT state_code, state_name, match_by_name, batch_id FROM src
    ON CONFLICT (state_code) DO UPDATE
       SET state_name = EXCLUDED.state_name, match_by_name = EXCLUDED.match_by_name,
           source_batch_id = EXCLUDED.source_batch_id
     WHERE (t.state_name, t.match_by_name) IS DISTINCT FROM (EXCLUDED.state_name, EXCLUDED.match_by_name)
    RETURNING (xmax = 0) AS inserted
)
INSERT INTO etl_step_log (batch_id, step_name, target_table, rows_processed, rows_inserted, rows_updated)
SELECT (SELECT b FROM latest), 'clean_reference', 'project_staging.stg_us_state',
       (SELECT count(*) FROM src), count(*) FILTER (WHERE inserted), count(*) FILTER (WHERE NOT inserted)
FROM up
HAVING (SELECT b FROM latest) IS NOT NULL;

/* ---- country aliases (MX -> Mexico, Burma (Myanmar) -> Myanmar ...) ------ */
WITH latest AS (
    SELECT max(batch_id) AS b FROM etl_batch
    WHERE source_name = 'ref_country_aliases' AND status IN ('RAW_LOADED', 'LOADED')
), src AS (
    SELECT DISTINCT ON (upper(fn_clean_text(r.alias)))
           upper(fn_clean_text(r.alias))  AS alias_upper,
           fn_clean_text(r.country)       AS country,
           r.batch_id
    FROM raw_country_alias r JOIN latest ON r.batch_id = latest.b
    WHERE fn_clean_text(r.alias) IS NOT NULL AND fn_clean_text(r.country) IS NOT NULL
    ORDER BY upper(fn_clean_text(r.alias)), r.source_row_num DESC
), up AS (
    INSERT INTO stg_country_alias AS t (alias_upper, country, source_batch_id)
    SELECT alias_upper, country, batch_id FROM src
    ON CONFLICT (alias_upper) DO UPDATE
       SET country = EXCLUDED.country, source_batch_id = EXCLUDED.source_batch_id
     WHERE t.country IS DISTINCT FROM EXCLUDED.country
    RETURNING (xmax = 0) AS inserted
)
INSERT INTO etl_step_log (batch_id, step_name, target_table, rows_processed, rows_inserted, rows_updated)
SELECT (SELECT b FROM latest), 'clean_reference', 'project_staging.stg_country_alias',
       (SELECT count(*) FROM src), count(*) FILTER (WHERE inserted), count(*) FILTER (WHERE NOT inserted)
FROM up
HAVING (SELECT b FROM latest) IS NOT NULL;

/* ---- close the reference batches ----------------------------------------- */
UPDATE etl_batch b
   SET status = 'LOADED',
       rows_staged = s.n,
       finished_at = now()
FROM (
    SELECT batch_id, count(*) AS n FROM (
        SELECT source_batch_id AS batch_id FROM stg_seismic_network
        UNION ALL SELECT source_batch_id FROM stg_magnitude_type
        UNION ALL SELECT source_batch_id FROM stg_us_state
        UNION ALL SELECT source_batch_id FROM stg_country_alias
    ) x GROUP BY batch_id
) s
WHERE b.batch_id = s.batch_id
  AND b.load_type = 'REFERENCE'
  AND b.status = 'RAW_LOADED';

-- reference batches whose rows were all unchanged (nothing re-staged) are also complete
UPDATE etl_batch
   SET status = 'LOADED', rows_staged = COALESCE(rows_staged, 0), finished_at = now()
 WHERE load_type = 'REFERENCE' AND status = 'RAW_LOADED';
