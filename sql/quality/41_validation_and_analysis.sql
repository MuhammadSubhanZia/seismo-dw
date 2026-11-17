/* ============================================================================
   41_validation_and_analysis.sql  -  warehouse validation & analytical checks

   Lab 06 sections 7.3, 8, 9, 10, 11 applied to the Seismo warehouse.
   Read-only (except the constraint test, which runs inside a rolled-back
   transaction). Each query is tagged "-- name:" so etl/build_reports.py can
   embed its result in the Data Quality Report.
   ============================================================================ */

SET search_path TO project_dw, project_staging, public;

-- name: dimension_uniqueness
-- Task 5.3: total rows vs distinct business keys in every dimension
SELECT 'dim_location' AS dimension, count(*) AS total_rows, count(DISTINCT location_code) AS distinct_business_keys FROM dim_location
UNION ALL SELECT 'dim_network (current versions)', count(*) FILTER (WHERE is_current), count(DISTINCT network_code) FROM dim_network
UNION ALL SELECT 'dim_magnitude_type', count(*), count(DISTINCT magnitude_type_code) FROM dim_magnitude_type
UNION ALL SELECT 'dim_event_type', count(*), count(DISTINCT event_type_code) FROM dim_event_type
UNION ALL SELECT 'dim_magnitude_class', count(*), count(DISTINCT magnitude_class) FROM dim_magnitude_class
UNION ALL SELECT 'dim_depth_class', count(*), count(DISTINCT depth_class) FROM dim_depth_class
UNION ALL SELECT 'dim_date', count(*), count(DISTINCT full_date) FROM dim_date;

-- name: surrogate_key_examples
-- Phase 2 section 4: business key retained next to the PostgreSQL-generated surrogate key
(SELECT 'dim_location' AS dimension, location_code AS business_key, location_key AS surrogate_key
   FROM dim_location WHERE location_key > 0 ORDER BY location_key LIMIT 3)
UNION ALL
(SELECT 'dim_network', network_code, network_key FROM dim_network WHERE network_key > 0 ORDER BY network_key LIMIT 3)
UNION ALL
(SELECT 'dim_magnitude_type', magnitude_type_code, magnitude_type_key FROM dim_magnitude_type WHERE magnitude_type_key > 0 ORDER BY magnitude_type_key LIMIT 3);

-- name: mapping_trace
-- Task 7.3 / Challenge A: source business keys -> surrogate keys -> fact row
SELECT f.event_id,
       s.location_code  AS src_location_code,  f.location_key,
       s.network_code   AS src_network_code,   f.network_key,
       s.magnitude_type AS src_magnitude_type, f.magnitude_type_key,
       to_char(s.event_time AT TIME ZONE 'UTC', 'YYYY-MM-DD') AS src_event_date, f.date_key,
       f.magnitude
FROM fact_seismic_event f
JOIN stg_seismic_event s ON s.event_id = f.event_id AND s.batch_id = f.updated_batch_id
WHERE f.event_id IN (SELECT event_id FROM fact_seismic_event ORDER BY magnitude DESC, event_id LIMIT 3)
ORDER BY f.magnitude DESC;

-- name: orphan_checks
-- Task 8.1: orphan detection for every foreign key (must all be 0)
SELECT (SELECT count(*) FROM fact_seismic_event f WHERE NOT EXISTS (SELECT 1 FROM dim_date d WHERE d.date_key = f.date_key))                         AS orphan_date,
       (SELECT count(*) FROM fact_seismic_event f WHERE NOT EXISTS (SELECT 1 FROM dim_location d WHERE d.location_key = f.location_key))             AS orphan_location,
       (SELECT count(*) FROM fact_seismic_event f WHERE NOT EXISTS (SELECT 1 FROM dim_network d WHERE d.network_key = f.network_key))                AS orphan_network,
       (SELECT count(*) FROM fact_seismic_event f WHERE NOT EXISTS (SELECT 1 FROM dim_magnitude_type d WHERE d.magnitude_type_key = f.magnitude_type_key)) AS orphan_magtype,
       (SELECT count(*) FROM fact_seismic_event f WHERE NOT EXISTS (SELECT 1 FROM dim_event_type d WHERE d.event_type_key = f.event_type_key))       AS orphan_event_type,
       (SELECT count(*) FROM fact_seismic_event f WHERE NOT EXISTS (SELECT 1 FROM dim_magnitude_class d WHERE d.magnitude_class_key = f.magnitude_class_key)) AS orphan_mag_class,
       (SELECT count(*) FROM fact_seismic_event f WHERE NOT EXISTS (SELECT 1 FROM dim_depth_class d WHERE d.depth_class_key = f.depth_class_key))    AS orphan_depth_class;

-- name: grain_reconciliation
-- Task 8.2: source rows -> eligible events -> fact rows, every difference explained
SELECT (SELECT count(*) FROM raw_usgs_event)                                         AS raw_rows_all_batches,
       (SELECT count(*) FROM rejected_event WHERE stage = 'STAGING')                 AS rejected_in_staging,
       (SELECT count(*) FROM stg_seismic_event)                                      AS staged_rows,
       (SELECT count(*) FROM rejected_event WHERE stage = 'FACT_LOAD')               AS rejected_in_fact_load,
       (SELECT count(*) FROM stg_seismic_event) - (SELECT count(*) FROM rejected_event WHERE stage = 'FACT_LOAD')
         - (SELECT count(DISTINCT event_id) FROM stg_seismic_event s
            WHERE NOT EXISTS (SELECT 1 FROM rejected_event r WHERE r.stage = 'FACT_LOAD' AND r.raw_id = s.raw_id))
                                                                                     AS repeat_deliveries_of_same_event,
       (SELECT count(*) FROM fact_seismic_event)                                     AS fact_rows;

-- name: batch_reconciliation
-- Lab 07 Task 7: counts and totals per batch (batch 1 vs batch 2 ...)
SELECT f.inserted_batch_id AS batch_id, b.source_file, count(*) AS fact_rows_first_loaded,
       round(sum(f.magnitude), 2) AS sum_magnitude, sum(f.energy_joules) AS sum_energy_joules
FROM fact_seismic_event f JOIN etl_batch b ON b.batch_id = f.inserted_batch_id
GROUP BY f.inserted_batch_id, b.source_file ORDER BY 1;

-- name: rejected_by_reason
-- Lab 07 Task 7: rejected rows by reason, even if zero
SELECT r.stage, r.reason_code, count(*) AS rows, min(r.batch_id) AS first_batch, max(r.batch_id) AS last_batch
FROM rejected_event r GROUP BY r.stage, r.reason_code ORDER BY r.stage, rows DESC;

-- name: source_vs_warehouse
-- Task 9.3: the same question answered from staging and from the star - totals agree
-- Q: number of 2025 events of magnitude >= 5.0 and their total energy, by quarter
WITH src AS (
    SELECT 'Q' || EXTRACT(QUARTER FROM event_time AT TIME ZONE 'UTC') AS quarter,
           count(*) AS events, sum(power(10::DOUBLE PRECISION, 1.5 * magnitude::DOUBLE PRECISION + 4.8)) AS energy
    FROM (SELECT DISTINCT ON (s.event_id) s.*
          FROM stg_seismic_event s
          WHERE s.is_active
            AND NOT EXISTS (SELECT 1 FROM rejected_event r WHERE r.stage = 'FACT_LOAD' AND r.raw_id = s.raw_id)
          ORDER BY s.event_id, s.source_updated_at DESC, s.batch_id) latest
    WHERE magnitude >= 5.0 AND EXTRACT(YEAR FROM event_time AT TIME ZONE 'UTC') = 2025
    GROUP BY 1
), dw AS (
    SELECT d.quarter_label AS quarter, count(*) AS events, sum(f.energy_joules) AS energy
    FROM fact_seismic_event f
    JOIN dim_date d ON d.date_key = f.date_key
    JOIN dim_magnitude_class mc ON mc.magnitude_class_key = f.magnitude_class_key
    WHERE d.year = 2025 AND mc.magnitude_class IN ('Strong', 'Major', 'Great')
    GROUP BY 1
)
SELECT src.quarter, src.events AS staging_events, dw.events AS warehouse_events,
       src.energy AS staging_energy_j, dw.energy AS warehouse_energy_j,
       src.events = dw.events AND abs(src.energy - dw.energy) <= 1e-9 * src.energy AS totals_agree
FROM src JOIN dw USING (quarter) ORDER BY quarter;

-- name: broken_load_simulation
-- Challenge C / Lab 07 applied challenge: duplicate ONE dimension mapping in a CTE and
-- show how the fact row count and energy inflate when the join key is not unique.
WITH broken_dim_network AS (
    SELECT network_key, network_code FROM dim_network WHERE is_current
    UNION ALL
    SELECT network_key, network_code FROM dim_network WHERE is_current AND network_code = 'ak'   -- duplicate business key
), latest AS (
    SELECT DISTINCT ON (s.event_id) s.*
    FROM stg_seismic_event s
    WHERE s.is_active
      AND NOT EXISTS (SELECT 1 FROM rejected_event r WHERE r.stage = 'FACT_LOAD' AND r.raw_id = s.raw_id)
    ORDER BY s.event_id, s.source_updated_at DESC, s.batch_id
)
SELECT 'correct load (unique dim_network)' AS scenario, count(*) AS fact_rows,
       sum(power(10::DOUBLE PRECISION, 1.5 * l.magnitude::DOUBLE PRECISION + 4.8)) AS total_energy_j
FROM latest l JOIN dim_network n ON n.network_code = l.network_code AND n.is_current
UNION ALL
SELECT 'broken load (network ak duplicated)', count(*),
       sum(power(10::DOUBLE PRECISION, 1.5 * l.magnitude::DOUBLE PRECISION + 4.8))
FROM latest l JOIN broken_dim_network n ON n.network_code = l.network_code;

-- name: duplicate_key_diagnostic
-- Section 10 diagnostics: each cause of "more fact rows / more energy than the source"
SELECT 'dimension business keys with >1 row (many-to-many mapping)' AS diagnostic,
       (SELECT count(*) FROM (SELECT location_code FROM dim_location GROUP BY 1 HAVING count(*) > 1) a)
     + (SELECT count(*) FROM (SELECT network_code FROM dim_network WHERE is_current GROUP BY 1 HAVING count(*) > 1) b)
     + (SELECT count(*) FROM (SELECT magnitude_type_code FROM dim_magnitude_type GROUP BY 1 HAVING count(*) > 1) c)
     + (SELECT count(*) FROM (SELECT event_type_code FROM dim_event_type GROUP BY 1 HAVING count(*) > 1) d) AS offending_rows
UNION ALL
SELECT 'source event loaded more than once (duplicate event_id in fact)',
       (SELECT count(*) FROM (SELECT event_id FROM fact_seismic_event GROUP BY 1 HAVING count(*) > 1) e)
UNION ALL
SELECT 'staged rows whose business key is cleaned differently from the dimension (unmapped)',
       (SELECT count(*) FROM stg_seismic_event s
        WHERE s.location_code IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dim_location l WHERE l.location_code = s.location_code))
UNION ALL
SELECT 'fact rows whose date_key disagrees with event_time (wrong-grain date join)',
       (SELECT count(*) FROM fact_seismic_event WHERE date_key <> to_char(event_time AT TIME ZONE 'UTC', 'YYYYMMDD')::INT);

-- name: analysis_events_by_location_type
-- Task 9.1 analogue: 2026 events and energy by location type and magnitude class
SELECT l.location_type, mc.magnitude_class, count(*) AS events,
       round(avg(f.magnitude), 2) AS avg_magnitude, sum(f.energy_tnt_tons)::BIGINT AS energy_tnt_tons
FROM fact_seismic_event f
JOIN dim_date d             ON d.date_key = f.date_key
JOIN dim_location l         ON l.location_key = f.location_key
JOIN dim_magnitude_class mc ON mc.magnitude_class_key = f.magnitude_class_key
WHERE d.year = 2026 AND f.is_active
GROUP BY l.location_type, mc.magnitude_class, mc.sort_order
ORDER BY l.location_type, mc.sort_order;

-- name: analysis_quarter_network
-- Task 9.2 analogue: quarter x network type x event origin for 2026, using dim_date attributes
SELECT d.quarter_label, n.network_type, et.event_origin, count(*) AS events,
       sum(f.felt_reports) AS felt_reports, count(DISTINCT f.location_key) AS distinct_locations
FROM fact_seismic_event f
JOIN dim_date d        ON d.date_key = f.date_key
JOIN dim_network n     ON n.network_key = f.network_key
JOIN dim_event_type et ON et.event_type_key = f.event_type_key
WHERE d.year = 2026 AND f.is_active
GROUP BY d.quarter_label, n.network_type, et.event_origin
ORDER BY d.quarter_label, events DESC;

-- name: top_locations
SELECT l.location_label, l.location_type, count(*) AS events, max(f.magnitude) AS max_magnitude
FROM fact_seismic_event f JOIN dim_location l ON l.location_key = f.location_key
WHERE f.is_active
GROUP BY l.location_label, l.location_type ORDER BY events DESC LIMIT 10;
