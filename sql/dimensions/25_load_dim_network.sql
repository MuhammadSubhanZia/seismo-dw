/* ============================================================================
   25_load_dim_network.sql  -  DIMENSION LOAD: dim_network  (SCD Type 2)

   Phase 2 version was SCD Type 1. Since Phase 3 (sql/dw/05_scd2_dim_network.sql)
   the dimension keeps one row per VERSION of a network:

   1. Inferred placeholder now supplied by the reference file -> Type 1 overwrite
      (the placeholder never described a real version of the network)
   2. Reference attributes changed for a current version      -> expire it
      (effective_to = load time, is_current = FALSE)
   3. Insert version n+1 for every expired code and version 1 for new codes
   4. Inferred members for network codes seen in events but missing from the
      reference file (e.g. 'ew'), flagged is_inferred = TRUE
   The fact load maps network_code to the row WHERE is_current.
   ============================================================================ */

SET search_path TO project_dw, project_staging, public;

INSERT INTO project_dw.dim_network
       (network_key, network_code, network_name, operator, region_served, network_type, is_inferred,
        effective_from, effective_to, is_current, version_no)
OVERRIDING SYSTEM VALUE
VALUES (-1, 'unknown', 'Unknown', 'Unknown', 'Unknown', 'Unknown', FALSE,
        TIMESTAMPTZ '2024-01-01 00:00:00+00', TIMESTAMPTZ '9999-12-31 00:00:00+00', TRUE, 1)
ON CONFLICT (network_key) DO NOTHING;

DROP TABLE IF EXISTS pg_temp._net_src;
CREATE TEMP TABLE _net_src AS
SELECT network_code,
       network_name,
       COALESCE(operator, 'Not specified')      AS operator,
       COALESCE(region_served, 'Not specified') AS region_served,
       COALESCE(network_type, 'Not specified')  AS network_type
FROM project_staging.stg_seismic_network;

-- 1) inferred placeholders filled in place
WITH upd AS (
    UPDATE project_dw.dim_network d
       SET network_name = s.network_name, operator = s.operator, region_served = s.region_served,
           network_type = s.network_type, is_inferred = FALSE, updated_at = now()
      FROM _net_src s
     WHERE d.network_code = s.network_code AND d.is_current AND d.is_inferred
    RETURNING 1
)
INSERT INTO project_staging.etl_step_log (batch_id, step_name, target_table, rows_updated, note)
SELECT NULLIF(current_setting('etl.batch_id', true), '')::BIGINT, 'load_dimension', 'project_dw.dim_network',
       (SELECT count(*) FROM upd), 'SCD2: inferred members completed in place';

-- 2) expire current versions whose attributes changed
DROP TABLE IF EXISTS pg_temp._net_expired;
CREATE TEMP TABLE _net_expired AS
WITH exp AS (
    UPDATE project_dw.dim_network d
       SET effective_to = now(), is_current = FALSE, updated_at = now()
      FROM _net_src s
     WHERE d.network_code = s.network_code
       AND d.is_current AND NOT d.is_inferred
       AND (d.network_name, d.operator, d.region_served, d.network_type)
           IS DISTINCT FROM (s.network_name, s.operator, s.region_served, s.network_type)
    RETURNING d.network_code, d.version_no
)
SELECT * FROM exp;

-- 3) new versions (changed codes) and first versions (new codes)
WITH ins AS (
    INSERT INTO project_dw.dim_network
           (network_code, network_name, operator, region_served, network_type, is_inferred,
            effective_from, effective_to, is_current, version_no)
    SELECT s.network_code, s.network_name, s.operator, s.region_served, s.network_type, FALSE,
           CASE WHEN e.network_code IS NULL THEN TIMESTAMPTZ '2024-01-01 00:00:00+00' ELSE now() END,
           TIMESTAMPTZ '9999-12-31 00:00:00+00', TRUE,
           COALESCE(e.version_no, 0) + 1
    FROM _net_src s
    LEFT JOIN _net_expired e ON e.network_code = s.network_code
    WHERE e.network_code IS NOT NULL
       OR NOT EXISTS (SELECT 1 FROM project_dw.dim_network d WHERE d.network_code = s.network_code)
    RETURNING version_no
)
INSERT INTO project_staging.etl_step_log (batch_id, step_name, target_table, rows_processed, rows_inserted, rows_updated, note)
SELECT NULLIF(current_setting('etl.batch_id', true), '')::BIGINT, 'load_dimension', 'project_dw.dim_network',
       (SELECT count(*) FROM _net_src),
       (SELECT count(*) FROM ins),
       (SELECT count(*) FROM _net_expired),
       format('SCD2: reference members - %s new code(s), %s new version(s), %s version(s) expired',
              (SELECT count(*) FROM ins WHERE version_no = 1),
              (SELECT count(*) FROM ins WHERE version_no > 1),
              (SELECT count(*) FROM _net_expired));

-- 4) inferred members
WITH ins AS (
    INSERT INTO project_dw.dim_network (network_code, network_name, operator, region_served, network_type, is_inferred)
    SELECT DISTINCT s.network_code, upper(s.network_code) || ' network (not in reference list)',
           'Unknown', 'Unknown', 'Unknown', TRUE
    FROM project_staging.stg_seismic_event s
    WHERE s.network_code IS NOT NULL
      AND (s.batch_id = NULLIF(current_setting('etl.batch_id', true), '')::BIGINT
           OR NULLIF(current_setting('etl.batch_id', true), '') IS NULL)
      AND NOT EXISTS (SELECT 1 FROM project_dw.dim_network d WHERE d.network_code = s.network_code)
    RETURNING 1
)
INSERT INTO project_staging.etl_step_log (batch_id, step_name, target_table, rows_inserted, note)
SELECT NULLIF(current_setting('etl.batch_id', true), '')::BIGINT, 'load_dimension', 'project_dw.dim_network',
       (SELECT count(*) FROM ins), 'inferred members';
