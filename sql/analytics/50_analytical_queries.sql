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

-- name: a08_rank_within_type
-- A08  RANK / DENSE_RANK inside a partition: top 3 locations per location type
SELECT location_type, location_label, events, rnk
FROM (
    SELECT l.location_type, l.location_label, count(*) AS events,
           dense_rank() OVER (PARTITION BY l.location_type ORDER BY count(*) DESC) AS rnk
    FROM fact_seismic_event f
    JOIN dim_location l ON l.location_key = f.location_key
    WHERE f.is_active AND l.location_key <> -1
    GROUP BY l.location_type, l.location_label
) r
WHERE rnk <= 3
ORDER BY location_type, rnk;

-- name: a09_depth_percentiles
-- A09  Distribution statistics per depth class: percentiles and standard deviation
SELECT dc.depth_class,
       count(*)                                                                AS events,
       round(avg(f.magnitude), 2)                                              AS avg_magnitude,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY f.magnitude)::NUMERIC, 2) AS median_magnitude,
       round(percentile_cont(0.9) WITHIN GROUP (ORDER BY f.magnitude)::NUMERIC, 2) AS p90_magnitude,
       round(stddev_samp(f.magnitude), 3)                                      AS stddev_magnitude,
       round(avg(f.felt_reports), 2)                                           AS avg_felt_reports
FROM fact_seismic_event f
JOIN dim_depth_class dc ON dc.depth_class_key = f.depth_class_key
WHERE f.is_active
GROUP BY dc.depth_class, dc.sort_order
ORDER BY dc.sort_order;

-- name: a10_network_contribution
-- A10  "Channel" analysis: which network types author the catalogue, with average review quality
SELECT n.network_type,
       count(*)                                                       AS events,
       round(100.0 * count(*) / sum(count(*)) OVER (), 2)             AS share_pct,
       round(avg(f.station_count), 1)                                 AS avg_stations,
       round(avg(f.azimuthal_gap), 1)                                 AS avg_azimuthal_gap,
       round(100.0 * count(*) FILTER (WHERE f.review_status = 'reviewed') / count(*), 2) AS reviewed_pct
FROM fact_seismic_event f
JOIN dim_network n ON n.network_key = f.network_key
WHERE f.is_active
GROUP BY n.network_type
ORDER BY events DESC;

-- name: a11_hour_of_day
-- A11  Time-of-day profile (natural events are uniform; blasts cluster in working hours)
SELECT et.event_origin,
       f.event_hour_utc,
       count(*) AS events
FROM fact_seismic_event f
JOIN dim_event_type et ON et.event_type_key = f.event_type_key
WHERE f.is_active AND et.event_origin IN ('Natural', 'Anthropogenic')
GROUP BY et.event_origin, f.event_hour_utc
ORDER BY et.event_origin, f.event_hour_utc;

-- name: a12_quarter_growth_by_type
-- A12  Quarter-over-quarter growth per location type (LAG partitioned by type)
SELECT location_type, year, quarter_label, events,
       round(100.0 * (events - lag(events) OVER w) / NULLIF(lag(events) OVER w, 0), 2) AS qoq_growth_pct
FROM (
    SELECT l.location_type, d.year, d.quarter, d.quarter_label, count(*) AS events
    FROM fact_seismic_event f
    JOIN dim_date d     ON d.date_key = f.date_key
    JOIN dim_location l ON l.location_key = f.location_key
    WHERE f.is_active AND l.location_key <> -1
    GROUP BY l.location_type, d.year, d.quarter, d.quarter_label
) q
WINDOW w AS (PARTITION BY location_type ORDER BY year, quarter)
ORDER BY location_type, year, quarter;

-- name: a13_strongest_events
-- A13  The 10 strongest events with their full dimensional context
SELECT f.event_id, d.full_date, l.location_label, f.magnitude, mt.magnitude_type_code,
       f.depth_km, round(f.energy_tnt_tons::NUMERIC, 0) AS energy_tnt_tons, f.alert_level, f.tsunami_flag
FROM fact_seismic_event f
JOIN dim_date d             ON d.date_key = f.date_key
JOIN dim_location l         ON l.location_key = f.location_key
JOIN dim_magnitude_type mt  ON mt.magnitude_type_key = f.magnitude_type_key
WHERE f.is_active
ORDER BY f.magnitude DESC, d.full_date
LIMIT 10;

-- name: a14_semi_additive_snapshot
-- A14  Periodic snapshot: semi-additive cumulative_events_ytd may be summed across locations
--      (one month) but not across months; December snapshot = full-year totals
SELECT d.year, d.month_name,
       sum(s.events_in_month)          AS events_in_month,           -- additive
       sum(s.cumulative_events_ytd)    AS cumulative_events_ytd,     -- semi-additive: OK across locations
       count(*) FILTER (WHERE s.is_active_month) AS active_locations,
       round(avg(s.days_since_last_event), 1)    AS avg_days_since_last_event  -- non-additive: average only
FROM fact_location_monthly_snapshot s
JOIN dim_date d ON d.date_key = s.snapshot_date_key
WHERE d.month = 12
   OR d.date_key = (SELECT max(snapshot_date_key) FROM fact_location_monthly_snapshot)   -- latest (partial) month
GROUP BY d.year, d.month, d.month_name
ORDER BY d.year, d.month;

-- name: a15_coverage_gaps
-- A15  Factless fact: locations covered by more than one network, and active locations with
--      only a single network (coverage-redundancy gap) in the latest year
SELECT CASE WHEN networks = 1 THEN 'single network' ELSE 'two or more networks' END AS coverage,
       count(*) AS locations
FROM (
    SELECT c.location_key, count(DISTINCT n.network_code) AS networks
    FROM fact_network_location_coverage c
    JOIN dim_network n ON n.network_key = c.network_key
    WHERE c.month_date_key >= 20260101
    GROUP BY c.location_key
) x
GROUP BY 1
ORDER BY 1;
