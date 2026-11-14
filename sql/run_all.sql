/* ============================================================================
   run_all.sql  -  psql master script (alternative to the Python orchestrator)

   The raw landing step (file -> raw_* tables) is done by Python
   (`python -m etl.run_pipeline ...`) because the USGS source is GeoJSON.
   This script recreates every object and re-runs the SQL transformation chain
   for one already-landed batch, which is handy for pgAdmin / psql review.

   Usage (from the repository root):
       psql -U postgres -d seismo_dw -v batch=5 -f sql/run_all.sql
   ============================================================================ */

\set ON_ERROR_STOP on

-- 1. structures (idempotent)
\i sql/01_create_schemas.sql
\i sql/staging/02_staging_schema.sql
\i sql/dw/03_dw_schema.sql
\i sql/reporting/04_reporting_schema.sql

BEGIN;
SELECT set_config('etl.batch_id', :'batch', true);

-- 2. ETL: reference data + events -> staging
\i sql/staging/11_clean_reference_to_staging.sql
\i sql/staging/12_clean_events_to_staging.sql

-- 3. dimensions BEFORE facts
\i sql/dimensions/20_load_dim_date.sql
\i sql/dimensions/21_load_dim_magnitude_class.sql
\i sql/dimensions/22_load_dim_depth_class.sql
\i sql/dimensions/23_load_dim_event_type.sql
\i sql/dimensions/24_load_dim_magnitude_type.sql
\i sql/dimensions/25_load_dim_network.sql
\i sql/dimensions/26_load_dim_location.sql

-- 4. fact (business key -> surrogate key)
\i sql/facts/30_load_fact_seismic_event.sql

-- 5. data quality
\i sql/quality/40_data_quality_checks.sql
COMMIT;

REFRESH MATERIALIZED VIEW project_reporting.mv_daily_location_activity;
SELECT check_code, status, check_name, expected_value, actual_value FROM project_reporting.vw_dq_latest_run;
