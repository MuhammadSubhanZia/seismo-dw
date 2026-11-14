/* ============================================================================
   24_load_dim_magnitude_type.sql  -  DIMENSION LOAD: dim_magnitude_type

   1. Reference members from stg_magnitude_type (UPSERT = SCD Type 1).
   2. Inferred members: a magnitude-type code that appears in the staged events but is
      missing from the reference file is inserted with is_inferred = TRUE, so the fact
      row can still map to a real surrogate key (late-arriving dimension pattern).
      When the reference file later supplies the code, step 1 overwrites the
      placeholder attributes and clears is_inferred.
   ============================================================================ */

SET search_path TO project_dw, project_staging, public;

INSERT INTO project_dw.dim_magnitude_type
       (magnitude_type_key, magnitude_type_code, magnitude_type_name, scale_family, description, is_inferred)
OVERRIDING SYSTEM VALUE
VALUES (-1, 'unknown', 'Unknown', 'Unknown', 'Magnitude type not reported', FALSE)
ON CONFLICT (magnitude_type_key) DO NOTHING;

-- 1) reference members
WITH up AS (
    INSERT INTO project_dw.dim_magnitude_type AS t
           (magnitude_type_code, magnitude_type_name, scale_family, description, is_inferred)
    SELECT magnitude_type_code, magnitude_type_name, scale_family,
           COALESCE(description, magnitude_type_name), FALSE
    FROM project_staging.stg_magnitude_type
    ON CONFLICT (magnitude_type_code) DO UPDATE
       SET magnitude_type_name = EXCLUDED.magnitude_type_name, scale_family = EXCLUDED.scale_family,
           description = EXCLUDED.description, is_inferred = FALSE, updated_at = now()
     WHERE (t.magnitude_type_name, t.scale_family, t.description, t.is_inferred)
           IS DISTINCT FROM (EXCLUDED.magnitude_type_name, EXCLUDED.scale_family, EXCLUDED.description, FALSE)
    RETURNING (xmax = 0) AS inserted
)
INSERT INTO project_staging.etl_step_log (batch_id, step_name, target_table, rows_processed, rows_inserted, rows_updated, note)
SELECT NULLIF(current_setting('etl.batch_id', true), '')::BIGINT, 'load_dimension', 'project_dw.dim_magnitude_type',
       (SELECT count(*) FROM project_staging.stg_magnitude_type),
       count(*) FILTER (WHERE inserted), count(*) FILTER (WHERE NOT inserted), 'reference members'
FROM up;

-- 2) inferred members for codes only seen in events
WITH ins AS (
    INSERT INTO project_dw.dim_magnitude_type (magnitude_type_code, magnitude_type_name, scale_family, description, is_inferred)
    SELECT DISTINCT s.magnitude_type, upper(s.magnitude_type) || ' (not in reference list)', 'Other',
           'Inferred member: code reported by USGS but missing from ref_magnitude_types.csv', TRUE
    FROM project_staging.stg_seismic_event s
    WHERE s.magnitude_type IS NOT NULL
      AND (s.batch_id = NULLIF(current_setting('etl.batch_id', true), '')::BIGINT
           OR NULLIF(current_setting('etl.batch_id', true), '') IS NULL)
    ON CONFLICT (magnitude_type_code) DO NOTHING
    RETURNING 1
)
INSERT INTO project_staging.etl_step_log (batch_id, step_name, target_table, rows_inserted, note)
SELECT NULLIF(current_setting('etl.batch_id', true), '')::BIGINT, 'load_dimension', 'project_dw.dim_magnitude_type',
       (SELECT count(*) FROM ins), 'inferred members';
