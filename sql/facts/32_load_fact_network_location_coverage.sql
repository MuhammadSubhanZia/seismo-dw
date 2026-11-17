/* ============================================================================
   32_load_fact_network_location_coverage.sql  -  FACTLESS FACT LOAD

   One row per (month, network, location) in which the network authored at least
   one active event solution for that location. Rebuilt from fact_seismic_event;
   the table holds keys only - no measures.
   ============================================================================ */

SET search_path TO project_dw, project_staging, public;

TRUNCATE project_dw.fact_network_location_coverage;

WITH ins AS (
    INSERT INTO project_dw.fact_network_location_coverage (month_date_key, network_key, location_key)
    SELECT DISTINCT (d.year * 10000 + d.month * 100 + 1) AS month_date_key, f.network_key, f.location_key
    FROM project_dw.fact_seismic_event f
    JOIN project_dw.dim_date d ON d.date_key = f.date_key
    WHERE f.is_active
    RETURNING 1
)
INSERT INTO project_staging.etl_step_log (batch_id, step_name, target_table, rows_processed, rows_inserted, note)
SELECT NULLIF(current_setting('etl.batch_id', true), '')::BIGINT, 'load_fact', 'project_dw.fact_network_location_coverage',
       (SELECT count(*) FROM project_dw.fact_seismic_event WHERE is_active), (SELECT count(*) FROM ins),
       'factless coverage fact rebuilt';
