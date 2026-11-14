/* ============================================================================
   04_reporting_schema.sql  -  REPORTING SCHEMA (project_reporting)

   Analyst / BI-facing objects built ONLY on project_dw (+ audit tables).
   Phase 2 creates the layer and its core objects; Phase 3 (OLAP / dashboards)
   extends it.

     vw_seismic_event_detail      denormalised star (fact + all dimensions)
     mv_daily_location_activity   aggregate: one row per date x location (materialized)
     vw_monthly_activity          monthly KPIs by magnitude class
     vw_etl_batch_summary         one row per load batch with row accounting
     vw_dq_latest_run             latest data-quality results
   Idempotent: safe to run more than once (views are replaced).
   ============================================================================ */

SET search_path TO project_reporting, public;

CREATE OR REPLACE VIEW project_reporting.vw_seismic_event_detail AS
SELECT f.event_id,
       f.event_time,
       d.full_date, d.year, d.quarter_label, d.month, d.month_name, d.year_month, d.day_name, d.is_weekend,
       f.event_hour_utc,
       l.location_label, l.country, l.state_province, l.location_type,
       n.network_code, n.network_name, n.network_type,
       mt.magnitude_type_code, mt.magnitude_type_name, mt.scale_family,
       et.event_type_label, et.event_origin,
       mc.magnitude_class, mc.sort_order AS magnitude_class_order,
       dc.depth_class, dc.sort_order AS depth_class_order,
       f.latitude, f.longitude, f.place, f.nearest_place,
       f.magnitude, f.depth_km, f.energy_joules, f.energy_tnt_tons,
       f.felt_reports, f.cdi, f.mmi, f.significance, f.station_count,
       f.alert_level, f.review_status, f.tsunami_flag, f.is_significant, f.is_active,
       f.event_count
FROM project_dw.fact_seismic_event f
JOIN project_dw.dim_date            d  ON d.date_key = f.date_key
JOIN project_dw.dim_location        l  ON l.location_key = f.location_key
JOIN project_dw.dim_network         n  ON n.network_key = f.network_key
JOIN project_dw.dim_magnitude_type  mt ON mt.magnitude_type_key = f.magnitude_type_key
JOIN project_dw.dim_event_type      et ON et.event_type_key = f.event_type_key
JOIN project_dw.dim_magnitude_class mc ON mc.magnitude_class_key = f.magnitude_class_key
JOIN project_dw.dim_depth_class     dc ON dc.depth_class_key = f.depth_class_key;

DROP MATERIALIZED VIEW IF EXISTS project_reporting.mv_daily_location_activity;
CREATE MATERIALIZED VIEW project_reporting.mv_daily_location_activity AS
SELECT f.date_key,
       f.location_key,
       count(*)                                              AS event_count,
       round(avg(f.magnitude), 3)                            AS avg_magnitude,
       max(f.magnitude)                                      AS max_magnitude,
       round(avg(f.depth_km), 2)                             AS avg_depth_km,
       sum(f.energy_joules)                                  AS total_energy_joules,
       count(*) FILTER (WHERE dc.depth_class = 'Shallow')    AS shallow_count,
       count(*) FILTER (WHERE dc.depth_class = 'Intermediate') AS intermediate_count,
       count(*) FILTER (WHERE dc.depth_class = 'Deep')       AS deep_count,
       count(*) FILTER (WHERE f.magnitude >= 5)              AS strong_plus_count,
       count(*) FILTER (WHERE f.is_significant)              AS significant_count,
       count(*) FILTER (WHERE f.tsunami_flag)                AS tsunami_count,
       sum(f.felt_reports)                                   AS felt_reports_total
FROM project_dw.fact_seismic_event f
JOIN project_dw.dim_depth_class dc ON dc.depth_class_key = f.depth_class_key
WHERE f.is_active
GROUP BY f.date_key, f.location_key
WITH DATA;
CREATE UNIQUE INDEX ux_mv_daily_location_activity ON project_reporting.mv_daily_location_activity (date_key, location_key);

CREATE OR REPLACE VIEW project_reporting.vw_monthly_activity AS
SELECT d.year, d.month, d.year_month, mc.magnitude_class, mc.sort_order,
       count(*)                     AS events,
       round(avg(f.magnitude), 2)   AS avg_magnitude,
       max(f.magnitude)             AS max_magnitude,
       sum(f.energy_joules)         AS total_energy_joules,
       sum(f.felt_reports)          AS felt_reports
FROM project_dw.fact_seismic_event f
JOIN project_dw.dim_date d             ON d.date_key = f.date_key
JOIN project_dw.dim_magnitude_class mc ON mc.magnitude_class_key = f.magnitude_class_key
WHERE f.is_active
GROUP BY d.year, d.month, d.year_month, mc.magnitude_class, mc.sort_order;

CREATE OR REPLACE VIEW project_reporting.vw_etl_batch_summary AS
SELECT b.batch_id, b.source_name, b.source_file, b.load_type, b.is_rerun, b.status,
       b.rows_read, b.rows_duplicate, b.rows_rejected, b.rows_staged,
       COALESCE(fl.rows_inserted, 0) AS fact_inserted,
       COALESCE(fl.rows_updated, 0)  AS fact_updated,
       fl.note                       AS fact_load_note,
       b.started_at, b.finished_at,
       round(EXTRACT(EPOCH FROM (b.finished_at - b.started_at))::NUMERIC, 1) AS duration_sec
FROM project_staging.etl_batch b
LEFT JOIN LATERAL (
    SELECT sum(rows_inserted) AS rows_inserted, sum(rows_updated) AS rows_updated, max(note) AS note
    FROM project_staging.etl_step_log s
    WHERE s.batch_id = b.batch_id AND s.step_name = 'load_fact'
) fl ON TRUE;

CREATE OR REPLACE VIEW project_reporting.vw_dq_latest_run AS
SELECT r.run_id, r.check_code, r.category, r.check_name, r.target_object,
       r.expected_value, r.actual_value, r.status, r.details, r.run_started_at
FROM project_staging.dq_check_result r
WHERE r.run_started_at = (SELECT max(run_started_at) FROM project_staging.dq_check_result)
ORDER BY r.check_code;
