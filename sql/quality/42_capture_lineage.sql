/* ============================================================================
   42_capture_lineage.sql  -  row counts per layer for the lineage trail

   Run at the end of every batch (inside the batch transaction). One capture =
   one row per object, all sharing captured_at = now().
   ============================================================================ */

SET search_path TO project_staging, project_dw, public;

INSERT INTO project_staging.meta_lineage_snapshot (run_id, layer, object_name, row_count)
SELECT NULLIF(current_setting('etl.batch_id', true), '')::BIGINT, layer, object_name, n
FROM (
    SELECT 1 AS o, 'Raw' AS layer, 'project_staging.raw_usgs_event' AS object_name, (SELECT count(*) FROM project_staging.raw_usgs_event) AS n
    UNION ALL SELECT 2, 'Staging', 'project_staging.stg_seismic_event', (SELECT count(*) FROM project_staging.stg_seismic_event)
    UNION ALL SELECT 3, 'Staging', 'project_staging.rejected_event', (SELECT count(*) FROM project_staging.rejected_event)
    UNION ALL SELECT 4, 'DW', 'project_dw.dim_location', (SELECT count(*) FROM project_dw.dim_location)
    UNION ALL SELECT 5, 'DW', 'project_dw.dim_network (all versions)', (SELECT count(*) FROM project_dw.dim_network)
    UNION ALL SELECT 6, 'DW', 'project_dw.fact_seismic_event', (SELECT count(*) FROM project_dw.fact_seismic_event)
    UNION ALL SELECT 7, 'DW', 'project_dw.fact_location_monthly_snapshot', (SELECT count(*) FROM project_dw.fact_location_monthly_snapshot)
    UNION ALL SELECT 8, 'DW', 'project_dw.fact_network_location_coverage', (SELECT count(*) FROM project_dw.fact_network_location_coverage)
    UNION ALL SELECT 9, 'Reporting', 'project_reporting.mv_daily_location_activity', (SELECT count(*) FROM project_reporting.mv_daily_location_activity)
) c
ORDER BY o;
