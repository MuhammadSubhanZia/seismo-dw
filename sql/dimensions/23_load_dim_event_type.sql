/* ============================================================================
   23_load_dim_event_type.sql  -  DIMENSION LOAD: dim_event_type

   Business key = cleaned (trimmed, lower-case) USGS event type.
   Label standardised to Title Case ("quarry blast" -> "Quarry Blast").
   New members are inserted with a PostgreSQL-generated surrogate key.
   ============================================================================ */

SET search_path TO project_dw, project_staging, public;

INSERT INTO project_dw.dim_event_type (event_type_key, event_type_code, event_type_label, event_origin)
OVERRIDING SYSTEM VALUE
VALUES (-1, 'unknown', 'Unknown', 'Unknown')
ON CONFLICT (event_type_key) DO NOTHING;

WITH src AS (
    SELECT DISTINCT s.event_type AS event_type_code
    FROM project_staging.stg_seismic_event s
    WHERE s.batch_id = NULLIF(current_setting('etl.batch_id', true), '')::BIGINT
       OR NULLIF(current_setting('etl.batch_id', true), '') IS NULL
), keyed AS (
    SELECT event_type_code,
           initcap(event_type_code) AS event_type_label,
           CASE WHEN event_type_code IN ('earthquake', 'ice quake', 'landslide', 'volcanic eruption',
                                         'rock burst', 'snow avalanche', 'volcanic explosion')
                     THEN 'Natural'
                WHEN event_type_code ~ '(explosion|blast|mine collapse|mining|nuclear|sonic boom|induced)'
                     THEN 'Anthropogenic'
                ELSE 'Other' END AS event_origin
    FROM src
    WHERE event_type_code IS NOT NULL
), ins AS (
    INSERT INTO project_dw.dim_event_type (event_type_code, event_type_label, event_origin)
    SELECT event_type_code, event_type_label, event_origin FROM keyed
    ON CONFLICT (event_type_code) DO NOTHING
    RETURNING 1
)
INSERT INTO project_staging.etl_step_log (batch_id, step_name, target_table, rows_processed, rows_inserted)
SELECT NULLIF(current_setting('etl.batch_id', true), '')::BIGINT, 'load_dimension', 'project_dw.dim_event_type',
       (SELECT count(*) FROM keyed), (SELECT count(*) FROM ins);
