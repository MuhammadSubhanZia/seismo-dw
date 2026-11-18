/* ============================================================================
   50_analytical_queries.sql  -  ANALYTICAL SQL LAYER (Phase 3, section 1)

   Deliverable: "Analytical SQL Queries (SQL)"      Aligned with Lab 01 + Lab 04 (ROLAP)

   Decision-support questions over the star schema using SUM / AVG / COUNT,
   GROUP BY / HAVING, Top-N and window functions (LAG, running totals, moving
   averages, RANK, NTILE, share of total, percentiles).
   Sales vocabulary of the brief -> seismic meaning (see 52_reporting_views.sql):
       revenue = energy released (TNT tons, additive)   orders = events
       customers = affected locations                    month | revenue | growth = A03

   Every query is tagged "-- name:" so etl/build_phase3_reports.py can run it and
   print its real output in the reports. Only active (not soft-deleted) events count.
   ============================================================================ */

SET search_path TO project_dw, project_reporting, public;

-- name: a01_headline_kpis
-- A01  Headline totals: SUM / AVG / COUNT over the whole warehouse
SELECT count(*)                                  AS events,                  -- "orders"
       round(sum(f.energy_tnt_tons)::NUMERIC, 0) AS energy_tnt_tons,         -- "revenue"
       count(DISTINCT f.location_key)            AS affected_locations,      -- "customers"
       round(avg(f.magnitude), 3)                AS avg_magnitude,
       max(f.magnitude)                          AS max_magnitude,
       round(avg(f.depth_km), 1)                 AS avg_depth_km,
       sum(f.felt_reports)                       AS felt_reports
FROM fact_seismic_event f
WHERE f.is_active;

-- name: a02_yearly_summary
-- A02  Year-level comparison (dim_date attributes, never parsing date_key)
SELECT d.year,
       count(*)                                  AS events,
       round(sum(f.energy_tnt_tons)::NUMERIC, 0) AS energy_tnt_tons,
       round(avg(f.magnitude), 3)                AS avg_magnitude,
       count(*) FILTER (WHERE f.magnitude >= 6)  AS major_or_greater,
       count(DISTINCT f.location_key)            AS affected_locations,
       count(DISTINCT d.full_date)               AS days_with_events
FROM fact_seismic_event f
JOIN dim_date d ON d.date_key = f.date_key
WHERE f.is_active
GROUP BY d.year
ORDER BY d.year;

-- name: a03_monthly_growth
-- A03  Month | Revenue | Growth  (energy and events with month-over-month growth via LAG)
SELECT year_month,
       events,
       round(total_energy_tnt_tons::NUMERIC, 0)  AS energy_tnt_tons,
       mom_event_growth_pct,
       mom_energy_growth_pct,
       yoy_event_growth_pct,
       events_3m_moving_avg
FROM project_reporting.vw_monthly_sales
ORDER BY year, month;

-- name: a04_top_locations
-- A04  Top-N: the 10 most active locations (aggregate first, then rank - Lab 04 rule)
SELECT rank() OVER (ORDER BY count(*) DESC)      AS rank,
       l.location_label,
       l.location_type,
       count(*)                                  AS events,
       round(avg(f.magnitude), 2)                AS avg_magnitude,
       max(f.magnitude)                          AS max_magnitude
FROM fact_seismic_event f
JOIN dim_location l ON l.location_key = f.location_key
WHERE f.is_active
GROUP BY l.location_label, l.location_type
ORDER BY events DESC
LIMIT 10;

-- name: a05_energy_concentration
-- A05  HAVING: locations that released more than 1 million tons of TNT-equivalent energy
SELECT l.location_label,
       count(*)                                  AS events,
       round(sum(f.energy_tnt_tons)::NUMERIC, 0) AS energy_tnt_tons,
       max(f.magnitude)                          AS max_magnitude
FROM fact_seismic_event f
JOIN dim_location l ON l.location_key = f.location_key
WHERE f.is_active
GROUP BY l.location_label
HAVING sum(f.energy_tnt_tons) > 1000000
ORDER BY energy_tnt_tons DESC;

-- name: a06_class_distribution
-- A06  Magnitude-class distribution with share of total (window over an aggregate)
SELECT mc.magnitude_class,
       mc.magnitude_range,
       count(*)                                                         AS events,
       round(100.0 * count(*) / sum(count(*)) OVER (), 2)               AS share_of_events_pct,
       round((100.0 * sum(f.energy_tnt_tons) / sum(sum(f.energy_tnt_tons)) OVER ())::NUMERIC, 2)
                                                                        AS share_of_energy_pct
FROM fact_seismic_event f
JOIN dim_magnitude_class mc ON mc.magnitude_class_key = f.magnitude_class_key
WHERE f.is_active
GROUP BY mc.magnitude_class, mc.magnitude_range, mc.sort_order
ORDER BY mc.sort_order;

-- name: a07_running_total
-- A07  Running total and 3-month moving average of events (cumulative window frames)
SELECT year_month,
       events,
       sum(events) OVER (ORDER BY year, month)                           AS running_events,
       events_ytd,
       events_3m_moving_avg
FROM project_reporting.vw_monthly_sales
ORDER BY year, month;
