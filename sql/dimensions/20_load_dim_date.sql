/* ============================================================================
   20_load_dim_date.sql  -  DIMENSION LOAD: dim_date

   Deliverable: "Dimension Load Scripts SQL"

   Generated with generate_series() - no manual inserts (Lab 06 Task 6.2).
   Required range 2024-01-01 .. 2026-12-31, automatically widened if staged events
   fall outside it. date_key = YYYYMMDD. Re-runnable: ON CONFLICT DO NOTHING.
   ============================================================================ */

SET search_path TO project_dw, project_staging, public;

WITH bounds AS (
    SELECT LEAST(DATE '2024-01-01',
                 (SELECT min((event_time AT TIME ZONE 'UTC')::DATE) FROM project_staging.stg_seismic_event)) AS d_from,
           GREATEST(DATE '2026-12-31',
                 (SELECT max((event_time AT TIME ZONE 'UTC')::DATE) FROM project_staging.stg_seismic_event)) AS d_to
), days AS (
    SELECT gs::DATE AS d
    FROM bounds, generate_series(bounds.d_from, bounds.d_to, INTERVAL '1 day') AS gs
), ins AS (
    INSERT INTO project_dw.dim_date (
        date_key, full_date, day_of_month, day_of_week, day_name, day_of_year, week_of_year,
        month, month_name, month_short, quarter, quarter_label, year, year_month, is_weekend)
    SELECT to_char(d, 'YYYYMMDD')::INT,
           d,
           EXTRACT(DAY FROM d)::SMALLINT,
           EXTRACT(ISODOW FROM d)::SMALLINT,
           trim(to_char(d, 'Day')),
           EXTRACT(DOY FROM d)::SMALLINT,
           EXTRACT(WEEK FROM d)::SMALLINT,
           EXTRACT(MONTH FROM d)::SMALLINT,
           trim(to_char(d, 'Month')),
           to_char(d, 'Mon'),
           EXTRACT(QUARTER FROM d)::SMALLINT,
           'Q' || EXTRACT(QUARTER FROM d),
           EXTRACT(YEAR FROM d)::SMALLINT,
           to_char(d, 'YYYY-MM'),
           EXTRACT(ISODOW FROM d) IN (6, 7)
    FROM days
    ON CONFLICT (date_key) DO NOTHING
    RETURNING 1
)
INSERT INTO project_staging.etl_step_log (batch_id, step_name, target_table, rows_processed, rows_inserted)
SELECT NULLIF(current_setting('etl.batch_id', true), '')::BIGINT, 'load_dimension', 'project_dw.dim_date',
       (SELECT count(*) FROM days), (SELECT count(*) FROM ins);
