/* ============================================================================
   51_olap_queries.sql  -  OLAP QUERIES (Phase 3, section 1 "OLAP Queries")

   Deliverable: "OLAP Queries (SQL)"                Aligned with Lab 04

   Hierarchies in the Seismo star (sales hierarchy of the brief in brackets):
       Region x product hierarchy   location_type -> event type -> magnitude class
                                    (Region -> Category -> Product)
       Geography   location_type  ->  country  ->  state_province
       Time        year -> quarter -> month
       Magnitude   magnitude_class -> magnitude_type
   Measure used for "revenue": energy released, SUM(energy_tnt_tons); events = COUNT(*).

   GROUPING(col) = 1 when a column was rolled up, so every subtotal row gets a
   readable label instead of an unexplained NULL (Lab 04 Task 6.2 / 7.4).
   Queries tagged "-- name:" are run by etl/build_phase3_reports.py.
   ============================================================================ */

SET search_path TO project_dw, project_reporting, public;

-- name: o01_rollup_region_category_product
-- O01  ROLLUP  Region -> Category -> Product  ==  location_type -> event type -> magnitude class
--      output: product rows, category subtotals, region subtotals and the grand total
SELECT CASE WHEN GROUPING(l.location_type) = 1    THEN 'GRAND TOTAL'
            WHEN GROUPING(et.event_type_label) = 1 THEN 'Region subtotal'
            WHEN GROUPING(mc.magnitude_class) = 1  THEN 'Category subtotal'
            ELSE 'Product row' END                              AS row_type,
       COALESCE(l.location_type, '(all regions)')               AS region,
       COALESCE(et.event_type_label, '(all categories)')        AS category,
       COALESCE(mc.magnitude_class, '(all products)')           AS product,
       count(*)                                                 AS events,
       round(sum(f.energy_tnt_tons)::NUMERIC, 1)                AS energy_tnt_tons
FROM fact_seismic_event f
JOIN dim_location l         ON l.location_key = f.location_key
JOIN dim_event_type et      ON et.event_type_key = f.event_type_key
JOIN dim_magnitude_class mc ON mc.magnitude_class_key = f.magnitude_class_key
WHERE f.is_active AND l.location_key <> -1
GROUP BY ROLLUP (l.location_type, et.event_type_label, mc.magnitude_class)
ORDER BY GROUPING(l.location_type), l.location_type, GROUPING(et.event_type_label), et.event_type_label,
         GROUPING(mc.magnitude_class), min(mc.sort_order);

-- name: o02_rollup_geography_all_regions
-- O02  Geographic hierarchy ROLLUP  location_type -> country -> state_province, keeping the
--      region subtotals and the grand total (the full output has one row per state/country too)
SELECT row_type, region, events, energy_tnt_tons
FROM (
    SELECT CASE WHEN GROUPING(l.location_type) = 1 THEN 'GRAND TOTAL'
                WHEN GROUPING(l.country) = 1        THEN 'Region subtotal'
                WHEN GROUPING(l.state_province) = 1 THEN 'Category subtotal'
                ELSE 'Product row' END                      AS row_type,
           COALESCE(l.location_type, '(all regions)')       AS region,
           count(*)                                         AS events,
           round(sum(f.energy_tnt_tons)::NUMERIC, 0)        AS energy_tnt_tons
    FROM fact_seismic_event f
    JOIN dim_location l ON l.location_key = f.location_key
    WHERE f.is_active
    GROUP BY ROLLUP (l.location_type, l.country, l.state_province)
) r
WHERE row_type IN ('Region subtotal', 'GRAND TOTAL')
ORDER BY row_type = 'GRAND TOTAL', events DESC;

-- name: o03_rollup_time
-- O03  ROLLUP  Year -> Quarter -> Month: monthly detail, quarter, year subtotals, grand total
SELECT CASE WHEN GROUPING(d.year) = 1          THEN 'GRAND TOTAL'
            WHEN GROUPING(d.quarter_label) = 1 THEN 'Year subtotal'
            WHEN GROUPING(d.month) = 1         THEN 'Quarter subtotal'
            ELSE 'Month' END                                    AS row_type,
       d.year, d.quarter_label, d.month,
       count(*)                                                 AS events,
       round(sum(f.energy_tnt_tons)::NUMERIC, 0)                AS energy_tnt_tons
FROM fact_seismic_event f
JOIN dim_date d ON d.date_key = f.date_key
WHERE f.is_active
GROUP BY ROLLUP (d.year, d.quarter_label, d.month)
ORDER BY d.year NULLS LAST, d.quarter_label NULLS LAST, d.month NULLS LAST;

-- name: o04_cube_region_channel
-- O04  CUBE  Region x Channel  ==  location_type x network_type
--      detail cells, region totals (all channels), channel totals (all regions), grand total
SELECT CASE WHEN GROUPING(l.location_type) = 1 AND GROUPING(n.network_type) = 1 THEN 'GRAND TOTAL'
            WHEN GROUPING(n.network_type) = 1 THEN 'Region total (all channels)'
            WHEN GROUPING(l.location_type) = 1 THEN 'Channel total (all regions)'
            ELSE 'Region x Channel' END                         AS row_type,
       COALESCE(l.location_type, '(all regions)')               AS region,
       COALESCE(n.network_type, '(all channels)')               AS channel,
       count(*)                                                 AS events,
       round(sum(f.energy_tnt_tons)::NUMERIC, 0)                AS energy_tnt_tons
FROM fact_seismic_event f
JOIN dim_location l ON l.location_key = f.location_key
JOIN dim_network n  ON n.network_key = f.network_key
WHERE f.is_active
GROUP BY CUBE (l.location_type, n.network_type)
ORDER BY GROUPING(l.location_type), GROUPING(n.network_type), region, events DESC;

-- name: o05_cube_sizes
-- O05  Lab 04 Task 7.3: adding a third dimension (magnitude class) multiplies the cube.
--      Row counts of the 2-D and 3-D cubes
SELECT '2-D cube: region x channel' AS cube, count(*) AS output_rows
FROM (SELECT 1 FROM fact_seismic_event f
      JOIN dim_location l ON l.location_key = f.location_key
      JOIN dim_network n  ON n.network_key = f.network_key
      WHERE f.is_active
      GROUP BY CUBE (l.location_type, n.network_type)) c2
UNION ALL
SELECT '3-D cube: region x channel x magnitude class', count(*)
FROM (SELECT 1 FROM fact_seismic_event f
      JOIN dim_location l         ON l.location_key = f.location_key
      JOIN dim_network n          ON n.network_key = f.network_key
      JOIN dim_magnitude_class mc ON mc.magnitude_class_key = f.magnitude_class_key
      WHERE f.is_active
      GROUP BY CUBE (l.location_type, n.network_type, mc.magnitude_class)) c3;

-- name: o06_cube_3d_labelled
-- O06  3-D CUBE with GROUPING-based labels (subtotal rows only, so a manager can read it)
SELECT CASE (GROUPING(l.location_type) * 4 + GROUPING(n.network_type) * 2 + GROUPING(mc.magnitude_class))
            WHEN 7 THEN 'GRAND TOTAL'
            WHEN 6 THEN 'Magnitude-class total'
            WHEN 5 THEN 'Channel total'
            WHEN 3 THEN 'Region total'
            WHEN 4 THEN 'Channel x Class'
            WHEN 2 THEN 'Region x Class'
            WHEN 1 THEN 'Region x Channel'
            ELSE 'Detail cell' END                              AS row_type,
       COALESCE(l.location_type, '(all)')                       AS region,
       COALESCE(n.network_type, '(all)')                        AS channel,
       COALESCE(mc.magnitude_class, '(all)')                    AS magnitude_class,
       count(*)                                                 AS events
FROM fact_seismic_event f
JOIN dim_location l         ON l.location_key = f.location_key
JOIN dim_network n          ON n.network_key = f.network_key
JOIN dim_magnitude_class mc ON mc.magnitude_class_key = f.magnitude_class_key
WHERE f.is_active
GROUP BY CUBE (l.location_type, n.network_type, mc.magnitude_class)
HAVING GROUPING(l.location_type) + GROUPING(n.network_type) + GROUPING(mc.magnitude_class) >= 2
ORDER BY GROUPING(l.location_type) + GROUPING(n.network_type) + GROUPING(mc.magnitude_class) DESC, events DESC;

-- name: o07_grouping_sets
-- O07  GROUPING SETS: three independent breakdowns in one pass (year, event origin, depth class)
SELECT CASE WHEN GROUPING(d.year) = 0         THEN 'by year'
            WHEN GROUPING(et.event_origin) = 0 THEN 'by event origin'
            WHEN GROUPING(dc.depth_class) = 0  THEN 'by depth class'
            ELSE 'GRAND TOTAL' END                              AS breakdown,
       COALESCE(d.year::TEXT, et.event_origin, dc.depth_class, '(all)') AS member,
       count(*)                                                 AS events
FROM fact_seismic_event f
JOIN dim_date d        ON d.date_key = f.date_key
JOIN dim_event_type et ON et.event_type_key = f.event_type_key
JOIN dim_depth_class dc ON dc.depth_class_key = f.depth_class_key
WHERE f.is_active
GROUP BY GROUPING SETS ((d.year), (et.event_origin), (dc.depth_class), ())
ORDER BY breakdown, events DESC;

-- name: o08_drilldown_year
-- O08  Drill-down step 1 (executive level): 2025 by year
SELECT d.year, count(*) AS events, round(sum(f.energy_tnt_tons)::NUMERIC, 0) AS energy_tnt_tons
FROM fact_seismic_event f JOIN dim_date d ON d.date_key = f.date_key
WHERE f.is_active AND d.year = 2025
GROUP BY d.year;

-- name: o09_drilldown_quarter
-- O09  Drill-down step 2: 2025 by quarter (one more GROUP BY column = one level deeper)
SELECT d.year, d.quarter_label, count(*) AS events, round(sum(f.energy_tnt_tons)::NUMERIC, 0) AS energy_tnt_tons
FROM fact_seismic_event f JOIN dim_date d ON d.date_key = f.date_key
WHERE f.is_active AND d.year = 2025
GROUP BY d.year, d.quarter_label
ORDER BY d.quarter_label;

-- name: o10_drilldown_month
-- O10  Drill-down step 3: 2025 by month (analyst level); July holds the M8.8 Kamchatka event
SELECT d.year, d.quarter_label, d.month, d.month_name, count(*) AS events,
       round(sum(f.energy_tnt_tons)::NUMERIC, 0) AS energy_tnt_tons
FROM fact_seismic_event f JOIN dim_date d ON d.date_key = f.date_key
WHERE f.is_active AND d.year = 2025
GROUP BY d.year, d.quarter_label, d.month, d.month_name
ORDER BY d.month;

-- name: o11_cross_grain
-- O11  Cross-dimensional grain (Lab 04 Task 8.3): one row = one quarter x one magnitude class
SELECT d.year, d.quarter_label, mc.magnitude_class, count(*) AS events
FROM fact_seismic_event f
JOIN dim_date d             ON d.date_key = f.date_key
JOIN dim_magnitude_class mc ON mc.magnitude_class_key = f.magnitude_class_key
WHERE f.is_active AND mc.magnitude_class IN ('Strong', 'Major', 'Great')
GROUP BY d.year, d.quarter, d.quarter_label, mc.magnitude_class, mc.sort_order
ORDER BY d.year, d.quarter, mc.sort_order;

/* ---------------------------------------------------------------------------
   MOLAP simulation (Lab 04 section 9): a physically stored pre-aggregate.
   Grain: one row per year + month + location type + magnitude class.
   --------------------------------------------------------------------------- */
DROP TABLE IF EXISTS project_reporting.agg_month_region_class;
CREATE TABLE project_reporting.agg_month_region_class AS
SELECT d.year, d.month, l.location_type AS region, mc.magnitude_class,
       count(*)                  AS events,
       sum(f.energy_tnt_tons)    AS energy_tnt_tons,
       sum(f.felt_reports)       AS felt_reports
FROM fact_seismic_event f
JOIN dim_date d             ON d.date_key = f.date_key
JOIN dim_location l         ON l.location_key = f.location_key
JOIN dim_magnitude_class mc ON mc.magnitude_class_key = f.magnitude_class_key
WHERE f.is_active
GROUP BY d.year, d.month, l.location_type, mc.magnitude_class;
ALTER TABLE project_reporting.agg_month_region_class
    ADD PRIMARY KEY (year, month, region, magnitude_class);

-- name: o12_molap_compression
-- O12  Compression of detail: fact rows / aggregate rows
SELECT (SELECT count(*) FROM fact_seismic_event WHERE is_active)            AS fact_rows,
       (SELECT count(*) FROM project_reporting.agg_month_region_class)      AS aggregate_rows,
       round((SELECT count(*) FROM fact_seismic_event WHERE is_active)::NUMERIC
             / (SELECT count(*) FROM project_reporting.agg_month_region_class), 1) AS compression_ratio;

-- name: o13_rolap_vs_molap
-- O13  Same question, two storage approaches: 2026 energy by region and magnitude class.
--      ROLAP joins and aggregates 3 tables at query time; the MOLAP-like table is read directly.
WITH rolap AS (
    SELECT l.location_type AS region, mc.magnitude_class, count(*) AS events, sum(f.energy_tnt_tons) AS energy
    FROM fact_seismic_event f
    JOIN dim_date d             ON d.date_key = f.date_key
    JOIN dim_location l         ON l.location_key = f.location_key
    JOIN dim_magnitude_class mc ON mc.magnitude_class_key = f.magnitude_class_key
    WHERE f.is_active AND d.year = 2026
    GROUP BY l.location_type, mc.magnitude_class
), molap AS (
    SELECT region, magnitude_class, sum(events) AS events, sum(energy_tnt_tons) AS energy
    FROM project_reporting.agg_month_region_class
    WHERE year = 2026
    GROUP BY region, magnitude_class
)
SELECT r.region, r.magnitude_class, r.events AS rolap_events, m.events AS molap_events,
       round(r.energy::NUMERIC, 1) AS rolap_energy, round(m.energy::NUMERIC, 1) AS molap_energy,
       r.events = m.events AND abs(r.energy - m.energy) <= 1e-9 * GREATEST(r.energy, 1) AS identical
FROM rolap r JOIN molap m USING (region, magnitude_class)
ORDER BY r.region, r.events DESC;

-- name: o14_detail_lost
-- O14  Challenge D: a question the aggregate CANNOT answer - which single day of 2025 had the
--      most strong (M5+) events? Day and magnitude detail were summed away in the aggregate.
SELECT d.full_date, count(*) AS strong_events
FROM fact_seismic_event f JOIN dim_date d ON d.date_key = f.date_key
WHERE f.is_active AND d.year = 2025 AND f.magnitude >= 5
GROUP BY d.full_date
ORDER BY strong_events DESC, d.full_date
LIMIT 5;

/* ---------------------------------------------------------------------------
   ROLAP vs MOLAP vs HOLAP in this project (Lab 04 Task 9.4)
     ROLAP  detail in project_dw fact/dimensions; any question, aggregation at query time
     MOLAP  agg_month_region_class / mv_daily_location_activity: pre-computed, fast,
            but fixed grain (O14 shows the lost detail)
     HOLAP  what the warehouse actually does: Power BI and the reporting views read the
            pre-aggregates for KPI cards and trends, and drill through to the relational
            fact for detail.
   --------------------------------------------------------------------------- */
