/* ============================================================================
   26_load_dim_location.sql  -  DIMENSION LOAD: dim_location

   Business key: location_code built in staging from the conformed
   (country, state_province) pair, e.g.
        'UNITED_STATES:CALIFORNIA'   'JAPAN'   'MID_ATLANTIC_RIDGE'
   Before -> after (Phase 2 section 4):
        location_code = 'UNITED_STATES:ALASKA'  ->  location_key = 10xx (PostgreSQL identity)
   New members are inserted; existing members get their descriptive attributes
   overwritten if they changed (SCD Type 1). Unknown member -1 = place not reported.
   ============================================================================ */

SET search_path TO project_dw, project_staging, public;

INSERT INTO project_dw.dim_location
       (location_key, location_code, country, state_province, location_label, location_type)
OVERRIDING SYSTEM VALUE
VALUES (-1, 'UNKNOWN', 'Unknown', 'N/A', 'Unknown', 'Unknown')
ON CONFLICT (location_key) DO NOTHING;

WITH src AS (
    -- one row per business key (deterministic if the same code ever had two spellings)
    SELECT DISTINCT ON (s.location_code)
           s.location_code,
           s.country,
           s.state_province,
           CASE WHEN s.state_province = 'N/A' THEN s.country
                ELSE s.state_province || ', ' || s.country END AS location_label,
           s.location_type
    FROM project_staging.stg_seismic_event s
    WHERE s.location_code IS NOT NULL
      AND (s.batch_id = NULLIF(current_setting('etl.batch_id', true), '')::BIGINT
           OR NULLIF(current_setting('etl.batch_id', true), '') IS NULL)
    ORDER BY s.location_code, s.country, s.state_province
), up AS (
    INSERT INTO project_dw.dim_location AS t (location_code, country, state_province, location_label, location_type)
    SELECT location_code, country, state_province, location_label, location_type FROM src
    ON CONFLICT (location_code) DO UPDATE
       SET country = EXCLUDED.country, state_province = EXCLUDED.state_province,
           location_label = EXCLUDED.location_label, location_type = EXCLUDED.location_type,
           updated_at = now()
     WHERE (t.country, t.state_province, t.location_label, t.location_type)
           IS DISTINCT FROM (EXCLUDED.country, EXCLUDED.state_province, EXCLUDED.location_label, EXCLUDED.location_type)
    RETURNING (xmax = 0) AS inserted
)
INSERT INTO project_staging.etl_step_log (batch_id, step_name, target_table, rows_processed, rows_inserted, rows_updated)
SELECT NULLIF(current_setting('etl.batch_id', true), '')::BIGINT, 'load_dimension', 'project_dw.dim_location',
       (SELECT count(*) FROM src), count(*) FILTER (WHERE inserted), count(*) FILTER (WHERE NOT inserted)
FROM up;
