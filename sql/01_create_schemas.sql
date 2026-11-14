/* ============================================================================
   01_create_schemas.sql
   Physical warehouse architecture (Phase 2, section 2):

        Source files (GeoJSON + CSV)
              |
              v
        project_staging   raw landing tables (as delivered) + cleaned stg_* tables
              |           + ETL control, rejected rows, data-quality results
              v
        project_dw        star schema: surrogate-key dimensions + fact table
              |
              v
        project_reporting  BI-facing views / materialized views (extended in Phase 3)

   Connect to database seismo_dw before running.
   ============================================================================ */

CREATE SCHEMA IF NOT EXISTS project_staging;
CREATE SCHEMA IF NOT EXISTS project_dw;
CREATE SCHEMA IF NOT EXISTS project_reporting;

COMMENT ON SCHEMA project_staging   IS 'Landing (raw_*) and cleaned (stg_*) tables, ETL control and data-quality audit';
COMMENT ON SCHEMA project_dw        IS 'Dimensional warehouse: surrogate-key dimensions and fact_seismic_event';
COMMENT ON SCHEMA project_reporting IS 'Reporting layer: analyst-friendly views over project_dw';
