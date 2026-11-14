/* ============================================================================
   25_load_dim_network.sql  -  DIMENSION LOAD: dim_network

   Same pattern as dim_magnitude_type:
   1. reference members from stg_seismic_network (UPSERT, SCD Type 1)
   2. inferred members for network codes seen in events but absent from the reference
      file (e.g. 'ew'), flagged is_inferred = TRUE.
   ============================================================================ */

SET search_path TO project_dw, project_staging, public;

INSERT INTO project_dw.dim_network
       (network_key, network_code, network_name, operator, region_served, network_type, is_inferred)
OVERRIDING SYSTEM VALUE
VALUES (-1, 'unknown', 'Unknown', 'Unknown', 'Unknown', 'Unknown', FALSE)
ON CONFLICT (network_key) DO NOTHING;

-- 1) reference members
WITH up AS (
    INSERT INTO project_dw.dim_network AS t
           (network_code, network_name, operator, region_served, network_type, is_inferred)
    SELECT network_code, network_name,
           COALESCE(operator, 'Not specified'), COALESCE(region_served, 'Not specified'),
           COALESCE(network_type, 'Not specified'), FALSE
    FROM project_staging.stg_seismic_network
    ON CONFLICT (network_code) DO UPDATE
       SET network_name = EXCLUDED.network_name, operator = EXCLUDED.operator,
           region_served = EXCLUDED.region_served, network_type = EXCLUDED.network_type,
           is_inferred = FALSE, updated_at = now()
     WHERE (t.network_name, t.operator, t.region_served, t.network_type, t.is_inferred)
           IS DISTINCT FROM (EXCLUDED.network_name, EXCLUDED.operator, EXCLUDED.region_served,
                             EXCLUDED.network_type, FALSE)
    RETURNING (xmax = 0) AS inserted
)
INSERT INTO project_staging.etl_step_log (batch_id, step_name, target_table, rows_processed, rows_inserted, rows_updated, note)
SELECT NULLIF(current_setting('etl.batch_id', true), '')::BIGINT, 'load_dimension', 'project_dw.dim_network',
       (SELECT count(*) FROM project_staging.stg_seismic_network),
       count(*) FILTER (WHERE inserted), count(*) FILTER (WHERE NOT inserted), 'reference members'
FROM up;

-- 2) inferred members
WITH ins AS (
    INSERT INTO project_dw.dim_network (network_code, network_name, operator, region_served, network_type, is_inferred)
    SELECT DISTINCT s.network_code, upper(s.network_code) || ' network (not in reference list)',
           'Unknown', 'Unknown', 'Unknown', TRUE
    FROM project_staging.stg_seismic_event s
    WHERE s.network_code IS NOT NULL
      AND (s.batch_id = NULLIF(current_setting('etl.batch_id', true), '')::BIGINT
           OR NULLIF(current_setting('etl.batch_id', true), '') IS NULL)
    ON CONFLICT (network_code) DO NOTHING
    RETURNING 1
)
INSERT INTO project_staging.etl_step_log (batch_id, step_name, target_table, rows_inserted, note)
SELECT NULLIF(current_setting('etl.batch_id', true), '')::BIGINT, 'load_dimension', 'project_dw.dim_network',
       (SELECT count(*) FROM ins), 'inferred members';
