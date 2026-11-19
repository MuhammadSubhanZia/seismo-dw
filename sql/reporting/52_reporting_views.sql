/* ============================================================================
   52_reporting_views.sql  -  REPORTING VIEWS (Phase 3, section 2)

   Deliverable: "Reporting Views (SQL)"

   The Phase 3 brief names three views written for a sales warehouse. They are kept
   under those exact names; their columns use the seismic meaning of each concept:

       sales concept   ->  Seismo DW meaning                     measure / column
       -------------       ---------------------------------     ------------------------------
       revenue         ->  radiated seismic energy               total_energy_tnt_tons (additive)
       order           ->  seismic event                         events
       customer        ->  affected location (country / state)   dim_location
       product         ->  magnitude class                       dim_magnitude_class
       category        ->  event type (earthquake, blast ...)    dim_event_type
       region          ->  location type (US / country / ocean)  dim_location.location_type
       channel         ->  seismic network type                  dim_network.network_type

   vw_monthly_sales        Month | Events | Energy | Growth (MoM, YoY, moving average, YTD)
   vw_customer_analysis    one row per location with RFM-style segmentation
                           (Recency of last event, Frequency of events, Magnitude of energy)
   vw_product_performance  one row per event type x magnitude class with shares and ranks
   All views read project_dw only and count active (not soft-deleted) events.
   ============================================================================ */

SET search_path TO project_reporting, project_dw, public;

/* ---------------------------------------------------------------------------
   vw_monthly_sales  -  monthly "revenue" (energy) and "orders" (events) with growth
   --------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW project_reporting.vw_monthly_sales AS
WITH monthly AS (
    SELECT d.year,
           d.month,
           min(d.month_name)                        AS month_name,
           min(d.year_month)                        AS year_month,
           make_date(d.year, d.month, 1)            AS month_start,
           count(*)                                 AS events,
           sum(f.energy_tnt_tons)                   AS total_energy_tnt_tons,
           sum(f.energy_joules)                     AS total_energy_joules,
           round(avg(f.magnitude), 3)               AS avg_magnitude,
           max(f.magnitude)                         AS max_magnitude,
           count(*) FILTER (WHERE f.magnitude >= 5) AS strong_events,
           sum(f.felt_reports)                      AS felt_reports,
           count(DISTINCT f.location_key)           AS active_locations
    FROM project_dw.fact_seismic_event f
    JOIN project_dw.dim_date d ON d.date_key = f.date_key
    WHERE f.is_active
    GROUP BY d.year, d.month
)
SELECT m.*,
       lag(m.events) OVER w                                                        AS prev_month_events,
       round(100.0 * (m.events - lag(m.events) OVER w) / NULLIF(lag(m.events) OVER w, 0), 2)
                                                                                   AS mom_event_growth_pct,
       round((100.0 * (m.total_energy_tnt_tons - lag(m.total_energy_tnt_tons) OVER w)
              / NULLIF(lag(m.total_energy_tnt_tons) OVER w, 0))::NUMERIC, 2)       AS mom_energy_growth_pct,
       lag(m.events, 12) OVER w                                                    AS same_month_last_year_events,
       round(100.0 * (m.events - lag(m.events, 12) OVER w) / NULLIF(lag(m.events, 12) OVER w, 0), 2)
                                                                                   AS yoy_event_growth_pct,
       round(avg(m.events) OVER (ORDER BY m.year, m.month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 1)
                                                                                   AS events_3m_moving_avg,
       sum(m.events) OVER (PARTITION BY m.year ORDER BY m.month)                   AS events_ytd
FROM monthly m
WINDOW w AS (ORDER BY m.year, m.month);

COMMENT ON VIEW project_reporting.vw_monthly_sales IS
    'Monthly activity: events (orders), energy (revenue) and growth. Sales-named per the Phase 3 brief.';

/* ---------------------------------------------------------------------------
   vw_customer_analysis  -  every affected location ("customer") with RFM segments
   --------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW project_reporting.vw_customer_analysis AS
WITH per_location AS (
    SELECT l.location_key,
           l.location_label,
           l.country,
           l.state_province,
           l.location_type,
           count(*)                                          AS events,
           sum(f.energy_tnt_tons)                            AS total_energy_tnt_tons,
           round(avg(f.magnitude), 3)                        AS avg_magnitude,
           max(f.magnitude)                                  AS max_magnitude,
           count(*) FILTER (WHERE f.magnitude >= 5)          AS strong_events,
           sum(f.felt_reports)                               AS felt_reports,
           count(DISTINCT d.year_month)                      AS active_months,
           min(d.full_date)                                  AS first_event_date,
           max(d.full_date)                                  AS last_event_date
    FROM project_dw.fact_seismic_event f
    JOIN project_dw.dim_location l ON l.location_key = f.location_key
    JOIN project_dw.dim_date d     ON d.date_key = f.date_key
    WHERE f.is_active AND l.location_key <> -1
    GROUP BY l.location_key, l.location_label, l.country, l.state_province, l.location_type
), scored AS (
    SELECT p.*,
           (SELECT max((event_time AT TIME ZONE 'UTC')::DATE) FROM project_dw.fact_seismic_event) - p.last_event_date
                                                             AS recency_days,
           ntile(5) OVER (ORDER BY p.last_event_date)        AS r_score,   -- 5 = most recent
           ntile(5) OVER (ORDER BY p.events)                 AS f_score,   -- 5 = most frequent
           ntile(5) OVER (ORDER BY p.total_energy_tnt_tons)  AS m_score    -- 5 = most energy released
    FROM per_location p
)
SELECT s.*,
       s.r_score * 100 + s.f_score * 10 + s.m_score          AS rfm_code,
       CASE
           WHEN s.r_score >= 4 AND s.f_score >= 4 AND s.m_score >= 4 THEN '1 Critical hotspot'
           WHEN s.f_score >= 4                                       THEN '2 Persistent activity'
           WHEN s.m_score >= 4                                       THEN '3 High-energy episodic'
           WHEN s.r_score >= 4                                       THEN '4 Recently active'
           WHEN s.r_score <= 2                                       THEN '6 Dormant'
           ELSE                                                           '5 Low activity'
       END                                                   AS activity_segment,
       round(100.0 * s.events / sum(s.events) OVER (), 3)    AS share_of_events_pct,
       rank() OVER (ORDER BY s.total_energy_tnt_tons DESC)   AS energy_rank
FROM scored s;

COMMENT ON VIEW project_reporting.vw_customer_analysis IS
    'One row per affected location (customer) with RFM-style activity segmentation. Sales-named per the Phase 3 brief.';

/* ---------------------------------------------------------------------------
   vw_product_performance  -  magnitude class ("product") within event type ("category")
   --------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW project_reporting.vw_product_performance AS
WITH perf AS (
    SELECT et.event_origin,
           et.event_type_label                          AS category,
           mc.magnitude_class                           AS product,
           mc.magnitude_range,
           mc.sort_order                                AS product_sort,
           count(*)                                     AS events,
           sum(f.energy_tnt_tons)                       AS total_energy_tnt_tons,
           round(avg(f.magnitude), 3)                   AS avg_magnitude,
           round(avg(f.depth_km), 2)                    AS avg_depth_km,
           round(avg(f.significance), 1)                AS avg_significance,
           sum(f.felt_reports)                          AS felt_reports,
           count(*) FILTER (WHERE f.is_significant)     AS significant_events,
           count(*) FILTER (WHERE f.tsunami_flag)       AS tsunami_events,
           count(DISTINCT f.location_key)               AS locations_affected
    FROM project_dw.fact_seismic_event f
    JOIN project_dw.dim_event_type et      ON et.event_type_key = f.event_type_key
    JOIN project_dw.dim_magnitude_class mc ON mc.magnitude_class_key = f.magnitude_class_key
    WHERE f.is_active
    GROUP BY et.event_origin, et.event_type_label, mc.magnitude_class, mc.magnitude_range, mc.sort_order
)
SELECT p.*,
       round(100.0 * p.events / sum(p.events) OVER (), 3)                                   AS share_of_events_pct,
       round((100.0 * p.total_energy_tnt_tons / sum(p.total_energy_tnt_tons) OVER ())::NUMERIC, 3) AS share_of_energy_pct,
       round(100.0 * p.events / sum(p.events) OVER (PARTITION BY p.category), 3)            AS share_within_category_pct,
       rank() OVER (ORDER BY p.total_energy_tnt_tons DESC)                                  AS energy_rank,
       rank() OVER (PARTITION BY p.category ORDER BY p.events DESC)                         AS rank_in_category
FROM perf p;

COMMENT ON VIEW project_reporting.vw_product_performance IS
    'Performance of each magnitude class (product) within each event type (category). Sales-named per the Phase 3 brief.';

/* ---------------------------------------------------------------------------
   Supporting BI views used by the Power BI model
   --------------------------------------------------------------------------- */

-- Strong (M5+) events per location, same calendar window (1 Jan - last loaded day) in the
-- latest and the previous year: the evidence behind decision 1 on the Decision page.
CREATE OR REPLACE VIEW project_reporting.vw_strong_event_growth AS
WITH bounds AS (
    SELECT max(d.full_date) AS last_day FROM project_dw.fact_seismic_event f
    JOIN project_dw.dim_date d ON d.date_key = f.date_key
), ytd AS (
    SELECT l.location_label, l.location_type, d.year, f.magnitude
    FROM project_dw.fact_seismic_event f
    JOIN project_dw.dim_date d     ON d.date_key = f.date_key
    JOIN project_dw.dim_location l ON l.location_key = f.location_key
    CROSS JOIN bounds b
    WHERE f.is_active AND l.location_key <> -1 AND f.magnitude >= 5
      AND d.year BETWEEN EXTRACT(YEAR FROM b.last_day) - 1 AND EXTRACT(YEAR FROM b.last_day)
      AND (d.month < EXTRACT(MONTH FROM b.last_day)
           OR (d.month = EXTRACT(MONTH FROM b.last_day) AND d.day_of_month <= EXTRACT(DAY FROM b.last_day)))
), agg AS (
    SELECT location_label, location_type,
           count(*) FILTER (WHERE year = (SELECT EXTRACT(YEAR FROM last_day) - 1 FROM bounds)) AS strong_prev_ytd,
           count(*) FILTER (WHERE year = (SELECT EXTRACT(YEAR FROM last_day) FROM bounds))     AS strong_curr_ytd
    FROM ytd GROUP BY location_label, location_type
)
SELECT a.*,
       round(100.0 * (a.strong_curr_ytd - a.strong_prev_ytd) / NULLIF(a.strong_prev_ytd, 0), 1) AS growth_pct,
       a.strong_curr_ytd >= 15 AS is_material
FROM agg a
WHERE a.strong_curr_ytd >= 15                       -- material locations only (percentages on tiny counts are noise)
ORDER BY growth_pct DESC NULLS LAST
LIMIT 10;
CREATE OR REPLACE VIEW project_reporting.vw_network_scd2_history AS
SELECT n.network_code, n.version_no, n.network_name, n.operator, n.network_type,
       n.effective_from, n.effective_to, n.is_current, n.is_inferred,
       (SELECT count(*) FROM project_dw.fact_seismic_event f WHERE f.network_key = n.network_key) AS facts_pointing_to_version
FROM project_dw.dim_network n
WHERE n.network_key <> -1;

CREATE OR REPLACE VIEW project_reporting.vw_data_lineage AS
SELECT e.hop_order, e.layer_from, e.object_from, e.layer_to, e.object_to, e.script, e.transformation
FROM project_staging.meta_lineage_edge e
ORDER BY e.hop_order, e.edge_id;
