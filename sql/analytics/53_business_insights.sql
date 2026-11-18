/* ============================================================================
   53_business_insights.sql  -  queries behind the Business Insights Report and the
                                 Decision page of the dashboard

   2026 is a partial year (data to 21 Nov), so every year-over-year comparison is
   YTD-ALIGNED: 1 Jan - 21 Nov of each year (day_of_year <= 325 / 326 in a leap year
   is avoided by comparing month/day directly).
   ============================================================================ */

SET search_path TO project_dw, project_reporting, public;

-- name: i01_ytd_by_region
-- I01  Events, strong events and energy per region type, same calendar window each year
WITH ytd AS (
    SELECT l.location_type, d.year, f.magnitude, f.energy_tnt_tons
    FROM fact_seismic_event f
    JOIN dim_date d     ON d.date_key = f.date_key
    JOIN dim_location l ON l.location_key = f.location_key
    WHERE f.is_active AND l.location_key <> -1
      AND (d.month < 11 OR (d.month = 11 AND d.day_of_month <= 21))
)
SELECT location_type,
       count(*) FILTER (WHERE year = 2025)                              AS events_ytd_2025,
       count(*) FILTER (WHERE year = 2026)                              AS events_ytd_2026,
       round(100.0 * (count(*) FILTER (WHERE year = 2026) - count(*) FILTER (WHERE year = 2025))
             / NULLIF(count(*) FILTER (WHERE year = 2025), 0), 1)       AS events_growth_pct,
       count(*) FILTER (WHERE year = 2025 AND magnitude >= 5)           AS strong_ytd_2025,
       count(*) FILTER (WHERE year = 2026 AND magnitude >= 5)           AS strong_ytd_2026,
       round(100.0 * (count(*) FILTER (WHERE year = 2026 AND magnitude >= 5) - count(*) FILTER (WHERE year = 2025 AND magnitude >= 5))
             / NULLIF(count(*) FILTER (WHERE year = 2025 AND magnitude >= 5), 0), 1) AS strong_growth_pct
FROM ytd
GROUP BY location_type
ORDER BY events_ytd_2026 DESC;

-- name: i02_growth_hotspots
-- I02  Locations whose strong (M5+) activity grew most, YTD 2026 vs YTD 2025
--      (minimum 15 strong events in 2026 so percentages are not noise)
WITH ytd AS (
    SELECT l.location_label, l.location_type, d.year, f.magnitude, f.energy_tnt_tons
    FROM fact_seismic_event f
    JOIN dim_date d     ON d.date_key = f.date_key
    JOIN dim_location l ON l.location_key = f.location_key
    WHERE f.is_active AND l.location_key <> -1 AND f.magnitude >= 5
      AND (d.month < 11 OR (d.month = 11 AND d.day_of_month <= 21))
)
SELECT location_label, location_type,
       count(*) FILTER (WHERE year = 2025) AS strong_ytd_2025,
       count(*) FILTER (WHERE year = 2026) AS strong_ytd_2026,
       round(100.0 * (count(*) FILTER (WHERE year = 2026) - count(*) FILTER (WHERE year = 2025))
             / NULLIF(count(*) FILTER (WHERE year = 2025), 0), 1) AS strong_growth_pct,
       max(magnitude) FILTER (WHERE year = 2026) AS max_mag_2026
FROM ytd
GROUP BY location_label, location_type
HAVING count(*) FILTER (WHERE year = 2026) >= 15
ORDER BY strong_growth_pct DESC NULLS LAST
LIMIT 10;

-- name: i03_energy_concentration
-- I03  How concentrated is risk? Share of events vs share of energy by magnitude class
SELECT magnitude_class, events, share_of_events_pct, share_of_energy_pct
FROM (
    SELECT mc.magnitude_class, mc.sort_order, count(*) AS events,
           round(100.0 * count(*) / sum(count(*)) OVER (), 2) AS share_of_events_pct,
           round((100.0 * sum(f.energy_tnt_tons) / sum(sum(f.energy_tnt_tons)) OVER ())::NUMERIC, 2) AS share_of_energy_pct
    FROM fact_seismic_event f
    JOIN dim_magnitude_class mc ON mc.magnitude_class_key = f.magnitude_class_key
    WHERE f.is_active
    GROUP BY mc.magnitude_class, mc.sort_order
) x
ORDER BY sort_order;

-- name: i04_single_network_hotspots
-- I04  High-activity locations covered by only ONE network in 2026 (factless coverage fact)
WITH cov AS (
    SELECT c.location_key, count(DISTINCT n.network_code) AS networks, string_agg(DISTINCT n.network_code, ',') AS codes
    FROM fact_network_location_coverage c
    JOIN dim_network n ON n.network_key = c.network_key
    WHERE c.month_date_key >= 20260101
    GROUP BY c.location_key
), act AS (
    SELECT f.location_key, count(*) AS events_2026, count(*) FILTER (WHERE f.magnitude >= 5) AS strong_2026,
           max(f.magnitude) AS max_mag_2026
    FROM fact_seismic_event f JOIN dim_date d ON d.date_key = f.date_key
    WHERE f.is_active AND d.year = 2026
    GROUP BY f.location_key
)
SELECT l.location_label, a.events_2026, a.strong_2026, a.max_mag_2026, c.codes AS covering_network
FROM cov c
JOIN act a           ON a.location_key = c.location_key
JOIN dim_location l  ON l.location_key = c.location_key
WHERE c.networks = 1
ORDER BY a.strong_2026 DESC, a.events_2026 DESC
LIMIT 10;

-- name: i05_single_network_share
-- I05  Share of 2026 strong (M5+) events that happened in single-network locations
WITH cov AS (
    SELECT c.location_key, count(DISTINCT n.network_code) AS networks
    FROM fact_network_location_coverage c JOIN dim_network n ON n.network_key = c.network_key
    WHERE c.month_date_key >= 20260101
    GROUP BY c.location_key
)
SELECT count(*) FILTER (WHERE c.networks = 1)                          AS strong_events_single_network,
       count(*)                                                       AS strong_events_total,
       round(100.0 * count(*) FILTER (WHERE c.networks = 1) / count(*), 1) AS single_network_share_pct
FROM fact_seismic_event f
JOIN dim_date d ON d.date_key = f.date_key
JOIN cov c      ON c.location_key = f.location_key
WHERE f.is_active AND d.year = 2026 AND f.magnitude >= 5;

-- name: i06_segment_summary
-- I06  Customer segmentation summary (vw_customer_analysis)
SELECT activity_segment, count(*) AS locations, sum(events) AS events,
       round(sum(total_energy_tnt_tons)::NUMERIC, 0) AS energy_tnt_tons,
       round(100.0 * sum(events) / sum(sum(events)) OVER (), 1) AS share_of_events_pct
FROM project_reporting.vw_customer_analysis
GROUP BY activity_segment
ORDER BY activity_segment;

-- name: i07_detection_bias
-- I07  Event counts vs magnitude: dense regional networks record many small events
SELECT l.location_label, count(*) AS events, round(avg(f.magnitude), 2) AS avg_magnitude,
       round(100.0 * count(*) FILTER (WHERE f.magnitude < 3) / count(*), 1) AS pct_below_m3,
       round(sum(f.energy_tnt_tons)::NUMERIC, 0) AS energy_tnt_tons
FROM fact_seismic_event f JOIN dim_location l ON l.location_key = f.location_key
WHERE f.is_active AND l.location_label IN ('Alaska, United States', 'Russia', 'Indonesia', 'Japan', 'California, United States')
GROUP BY l.location_label
ORDER BY events DESC;

-- name: i08_review_latency
-- I08  Data freshness: share of 2026 events still 'automatic' (not yet analyst-reviewed)
SELECT d.month_name, count(*) AS events,
       count(*) FILTER (WHERE f.review_status = 'automatic') AS automatic_events,
       round(100.0 * count(*) FILTER (WHERE f.review_status = 'automatic') / count(*), 1) AS automatic_pct
FROM fact_seismic_event f JOIN dim_date d ON d.date_key = f.date_key
WHERE f.is_active AND d.year = 2026 AND d.month >= 9
GROUP BY d.month, d.month_name
ORDER BY d.month;
