/* ============================================================================
   40_data_quality_checks.sql  -  DATA QUALITY VALIDATION (Phase 2, section 6)

   Writes one row per check into project_staging.dq_check_result
   (run_id = batch that triggered the run). Status PASS / FAIL, or INFO for
   profile metrics that have no pass/fail threshold.

   COMPLETENESS  missing values, every raw row accounted for, every eligible event loaded
   ACCURACY      reconciliation of counts and measures (the seismic equivalent of
                 "revenue reconciliation" is ENERGY reconciliation: SUM(energy_joules)),
                 raw-JSON -> warehouse value checks, derived-measure checks, valid ranges
   INTEGRITY     foreign-key validation: fact rows without matching dimension = 0
   UNIQUENESS    one row per business key in every dimension, one row per event in the fact
   CONSISTENCY   class bands agree with the numeric measure, date coverage

   Run by the pipeline after every batch, or manually:
        SELECT set_config('etl.batch_id', '<id>', false);  -- optional
        \i sql/quality/40_data_quality_checks.sql
        SELECT * FROM project_reporting.vw_dq_latest_run;
   ============================================================================ */

SET search_path TO project_staging, project_dw, public;

DROP TABLE IF EXISTS pg_temp._dq;
CREATE TEMP TABLE _dq AS
SELECT COALESCE(NULLIF(current_setting('etl.batch_id', true), '')::BIGINT,
                (SELECT max(batch_id) FROM etl_batch)) AS run_id;

-- Eligible staged rows = staged rows that were not rejected at the fact stage.
DROP TABLE IF EXISTS pg_temp._eligible;
CREATE TEMP TABLE _eligible AS
SELECT s.*
FROM stg_seismic_event s
WHERE NOT EXISTS (SELECT 1 FROM rejected_event r
                  WHERE r.stage = 'FACT_LOAD' AND r.batch_id = s.batch_id AND r.raw_id = s.raw_id);

-- Expected warehouse content: latest ACTIVE version of every eligible event
-- (ties on the USGS version timestamp keep the first batch, exactly like the upsert guard).
DROP TABLE IF EXISTS pg_temp._expected;
CREATE TEMP TABLE _expected AS
SELECT DISTINCT ON (event_id) *
FROM _eligible
WHERE is_active
ORDER BY event_id, source_updated_at DESC, batch_id ASC;

-- Expected soft deletes: events whose newest eligible version is a deletion newer than the active one
DROP TABLE IF EXISTS pg_temp._expected_deleted;
CREATE TEMP TABLE _expected_deleted AS
SELECT d.event_id
FROM (SELECT DISTINCT ON (event_id) event_id, is_active, source_updated_at
      FROM _eligible ORDER BY event_id, source_updated_at DESC, batch_id ASC) d
JOIN _expected e USING (event_id)
WHERE NOT d.is_active AND d.source_updated_at > e.source_updated_at
UNION
-- alias ids loaded before their preferred event arrived (deactivated as 'superseded')
SELECT a.event_id
FROM _expected a
JOIN (SELECT unnest(associated_ids) AS alias_id, event_id AS preferred_id FROM _expected) p
  ON p.alias_id = a.event_id AND p.preferred_id <> a.event_id;

/* ===================== COMPLETENESS ===================================== */

-- C01 every raw row of every events batch is either staged or rejected (nothing silently lost)
INSERT INTO dq_check_result (run_id, check_code, category, check_name, target_object, expected_value, actual_value, status, details)
SELECT (SELECT run_id FROM _dq), 'C01', 'COMPLETENESS', 'Raw rows accounted for (raw = staged + rejected at staging)',
       'raw_usgs_event -> stg_seismic_event', raw_n, staged_n + rej_n,
       CASE WHEN raw_n = staged_n + rej_n THEN 'PASS' ELSE 'FAIL' END,
       format('raw=%s staged=%s staging rejects=%s', raw_n, staged_n, rej_n)
FROM (SELECT (SELECT count(*) FROM raw_usgs_event) AS raw_n,
             (SELECT count(*) FROM stg_seismic_event) AS staged_n,
             (SELECT count(*) FROM rejected_event WHERE stage = 'STAGING') AS rej_n) x;

-- C02 required fact columns have no missing values
INSERT INTO dq_check_result (run_id, check_code, category, check_name, target_object, expected_value, actual_value, status, details)
SELECT (SELECT run_id FROM _dq), 'C02', 'COMPLETENESS', 'Missing values in required fact columns',
       'fact_seismic_event', 0, n, CASE WHEN n = 0 THEN 'PASS' ELSE 'FAIL' END,
       'event_id, all 7 surrogate keys, event_time, magnitude, depth_km, latitude, longitude, energy_joules'
FROM (SELECT count(*) AS n FROM fact_seismic_event
      WHERE event_id IS NULL OR date_key IS NULL OR location_key IS NULL OR network_key IS NULL
         OR magnitude_type_key IS NULL OR event_type_key IS NULL OR magnitude_class_key IS NULL
         OR depth_class_key IS NULL OR event_time IS NULL OR magnitude IS NULL OR depth_km IS NULL
         OR latitude IS NULL OR longitude IS NULL OR energy_joules IS NULL) x;

-- C03 every eligible staged event reached the warehouse
INSERT INTO dq_check_result (run_id, check_code, category, check_name, target_object, expected_value, actual_value, status, details)
SELECT (SELECT run_id FROM _dq), 'C03', 'COMPLETENESS', 'Eligible staged events missing from the fact',
       'stg_seismic_event -> fact_seismic_event', 0, n, CASE WHEN n = 0 THEN 'PASS' ELSE 'FAIL' END, NULL
FROM (SELECT count(*) AS n FROM _expected e
      WHERE NOT EXISTS (SELECT 1 FROM fact_seismic_event f WHERE f.event_id = e.event_id)) x;

-- C04-C09 missing-value profile of optional source attributes (raw JSON, all batches) - INFO
INSERT INTO dq_check_result (run_id, check_code, category, check_name, target_object, expected_value, actual_value, status, details)
SELECT (SELECT run_id FROM _dq), code, 'COMPLETENESS', 'Missing values in source attribute: ' || attr,
       'raw_usgs_event', NULL, round(100.0 * nulls / NULLIF(total, 0), 2), 'INFO',
       format('%s of %s raw rows NULL (%s%%). Handling: %s', nulls, total,
              round(100.0 * nulls / NULLIF(total, 0), 2), handling)
FROM (
    SELECT 'C04' AS code, 'felt' AS attr, count(*) FILTER (WHERE felt IS NULL) AS nulls, count(*) AS total,
           'NULL = no DYFI reports -> felt_reports = 0' AS handling FROM v_raw_usgs_event_flat
    UNION ALL SELECT 'C05', 'cdi', count(*) FILTER (WHERE cdi IS NULL), count(*), 'kept NULL (not measured)' FROM v_raw_usgs_event_flat
    UNION ALL SELECT 'C06', 'mmi', count(*) FILTER (WHERE mmi IS NULL), count(*), 'kept NULL (not measured)' FROM v_raw_usgs_event_flat
    UNION ALL SELECT 'C07', 'alert', count(*) FILTER (WHERE alert IS NULL), count(*), 'NULL = no PAGER alert -> alert_level = none' FROM v_raw_usgs_event_flat
    UNION ALL SELECT 'C08', 'nst / gap', count(*) FILTER (WHERE nst IS NULL OR gap IS NULL), count(*), 'kept NULL (network did not report)' FROM v_raw_usgs_event_flat
    UNION ALL SELECT 'C09', 'magType', count(*) FILTER (WHERE mag_type IS NULL), count(*), 'mapped to Unknown member (-1)' FROM v_raw_usgs_event_flat
) p;

/* ===================== ACCURACY (reconciliation) ======================== */

-- A01 row-count reconciliation: expected events vs fact rows
INSERT INTO dq_check_result (run_id, check_code, category, check_name, target_object, expected_value, actual_value, status, details)
SELECT (SELECT run_id FROM _dq), 'A01', 'ACCURACY', 'Row-count reconciliation (distinct eligible events vs fact rows)',
       'fact_seismic_event', e, f, CASE WHEN e = f THEN 'PASS' ELSE 'FAIL' END,
       format('expected=%s fact=%s difference=%s', e, f, f - e)
FROM (SELECT (SELECT count(*) FROM _expected) AS e, (SELECT count(*) FROM fact_seismic_event) AS f) x;

-- A02-A05 measure reconciliation (latest staged version vs warehouse)
INSERT INTO dq_check_result (run_id, check_code, category, check_name, target_object, expected_value, actual_value, status, details)
SELECT (SELECT run_id FROM _dq), code, 'ACCURACY', name, 'fact_seismic_event', e, f,
       CASE WHEN abs(e - f) <= tol * GREATEST(abs(e), 1) THEN 'PASS' ELSE 'FAIL' END,
       format('staging=%s warehouse=%s difference=%s', e, f, f - e)
FROM (
    SELECT 'A02' AS code, 'Measure reconciliation: SUM(magnitude)' AS name,
           (SELECT sum(magnitude) FROM _expected)::NUMERIC AS e,
           (SELECT sum(magnitude) FROM fact_seismic_event)::NUMERIC AS f, 0::NUMERIC AS tol
    UNION ALL
    SELECT 'A03', 'Energy reconciliation (revenue-equivalent): SUM(energy_joules)',
           (SELECT sum(power(10::DOUBLE PRECISION, 1.5 * magnitude::DOUBLE PRECISION + 4.8)) FROM _expected)::NUMERIC,
           (SELECT sum(energy_joules) FROM fact_seismic_event)::NUMERIC, 1e-9
    UNION ALL
    SELECT 'A04', 'Measure reconciliation: SUM(felt_reports)',
           (SELECT sum(felt_reports) FROM _expected)::NUMERIC, (SELECT sum(felt_reports) FROM fact_seismic_event)::NUMERIC, 0
    UNION ALL
    SELECT 'A05', 'Measure reconciliation: SUM(significance)',
           (SELECT sum(significance) FROM _expected)::NUMERIC, (SELECT sum(significance) FROM fact_seismic_event)::NUMERIC, 0
) r;

-- A06 soft-delete reconciliation
INSERT INTO dq_check_result (run_id, check_code, category, check_name, target_object, expected_value, actual_value, status, details)
SELECT (SELECT run_id FROM _dq), 'A06', 'ACCURACY', 'Inactive events match USGS deletions + superseded alias ids',
       'fact_seismic_event.is_active', e, f, CASE WHEN e = f THEN 'PASS' ELSE 'FAIL' END, NULL
FROM (SELECT (SELECT count(*) FROM _expected_deleted) AS e,
             (SELECT count(*) FROM fact_seismic_event WHERE NOT is_active) AS f) x;

-- A07 raw JSON -> warehouse value check (magnitude, depth, coordinates, time) for every active fact row
INSERT INTO dq_check_result (run_id, check_code, category, check_name, target_object, expected_value, actual_value, status, details)
SELECT (SELECT run_id FROM _dq), 'A07', 'ACCURACY', 'Fact values differ from the raw source feature they came from',
       'raw_usgs_event -> fact_seismic_event', 0, n, CASE WHEN n = 0 THEN 'PASS' ELSE 'FAIL' END,
       'compares fact magnitude/depth/lat/lon/event_time with the raw GeoJSON of the loaded version'
FROM (
    SELECT count(*) AS n
    FROM fact_seismic_event f
    JOIN stg_seismic_event s ON s.event_id = f.event_id AND s.batch_id = f.updated_batch_id
    JOIN raw_usgs_event r    ON r.raw_id = s.raw_id
    WHERE f.is_active
      AND (   f.magnitude <> round((r.feature -> 'properties' ->> 'mag')::NUMERIC, 2)
           OR f.depth_km  <> round((r.feature -> 'geometry' -> 'coordinates' ->> 2)::NUMERIC, 3)
           OR f.latitude  <> round((r.feature -> 'geometry' -> 'coordinates' ->> 1)::NUMERIC, 6)
           OR f.longitude <> round((r.feature -> 'geometry' -> 'coordinates' ->> 0)::NUMERIC, 6)
           OR f.event_time <> to_timestamp((r.feature -> 'properties' ->> 'time')::NUMERIC / 1000.0))
) x;

-- A08 derived measure: energy_joules = 10^(1.5 M + 4.8)
INSERT INTO dq_check_result (run_id, check_code, category, check_name, target_object, expected_value, actual_value, status, details)
SELECT (SELECT run_id FROM _dq), 'A08', 'ACCURACY', 'Derived energy_joules / energy_tnt_tons recomputation errors',
       'fact_seismic_event', 0, n, CASE WHEN n = 0 THEN 'PASS' ELSE 'FAIL' END, 'Gutenberg-Richter energy relation'
FROM (SELECT count(*) AS n FROM fact_seismic_event
      WHERE abs(energy_joules - power(10::DOUBLE PRECISION, 1.5 * magnitude::DOUBLE PRECISION + 4.8)) > 1e-9 * energy_joules
         OR abs(energy_tnt_tons - energy_joules / 4.184e9) > 1e-9 * energy_tnt_tons) x;

-- A09 valid ranges (validity)
INSERT INTO dq_check_result (run_id, check_code, category, check_name, target_object, expected_value, actual_value, status, details)
SELECT (SELECT run_id FROM _dq), 'A09', 'VALIDITY', 'Out-of-range values (lat, lon, magnitude, depth, future time)',
       'fact_seismic_event', 0, n, CASE WHEN n = 0 THEN 'PASS' ELSE 'FAIL' END,
       'lat [-90,90], lon [-180,180], magnitude [-2,10], depth [-10,800] km, event_time <= load time'
FROM (SELECT count(*) AS n FROM fact_seismic_event
      WHERE latitude NOT BETWEEN -90 AND 90 OR longitude NOT BETWEEN -180 AND 180
         OR magnitude NOT BETWEEN -2 AND 10 OR depth_km NOT BETWEEN -10 AND 800
         OR event_time > dw_created_at + INTERVAL '1 day') x;

/* ===================== INTEGRITY (foreign keys) ========================= */

INSERT INTO dq_check_result (run_id, check_code, category, check_name, target_object, expected_value, actual_value, status, details)
SELECT (SELECT run_id FROM _dq), code, 'INTEGRITY', 'Fact rows without matching dimension: ' || dim,
       'fact_seismic_event.' || fk, 0, n, CASE WHEN n = 0 THEN 'PASS' ELSE 'FAIL' END, 'LEFT JOIN anti-check'
FROM (
    SELECT 'I01' AS code, 'dim_date' AS dim, 'date_key' AS fk,
           (SELECT count(*) FROM fact_seismic_event f LEFT JOIN dim_date d USING (date_key) WHERE d.date_key IS NULL) AS n
    UNION ALL SELECT 'I02', 'dim_location', 'location_key',
           (SELECT count(*) FROM fact_seismic_event f LEFT JOIN dim_location d USING (location_key) WHERE d.location_key IS NULL)
    UNION ALL SELECT 'I03', 'dim_network', 'network_key',
           (SELECT count(*) FROM fact_seismic_event f LEFT JOIN dim_network d USING (network_key) WHERE d.network_key IS NULL)
    UNION ALL SELECT 'I04', 'dim_magnitude_type', 'magnitude_type_key',
           (SELECT count(*) FROM fact_seismic_event f LEFT JOIN dim_magnitude_type d USING (magnitude_type_key) WHERE d.magnitude_type_key IS NULL)
    UNION ALL SELECT 'I05', 'dim_event_type', 'event_type_key',
           (SELECT count(*) FROM fact_seismic_event f LEFT JOIN dim_event_type d USING (event_type_key) WHERE d.event_type_key IS NULL)
    UNION ALL SELECT 'I06', 'dim_magnitude_class', 'magnitude_class_key',
           (SELECT count(*) FROM fact_seismic_event f LEFT JOIN dim_magnitude_class d USING (magnitude_class_key) WHERE d.magnitude_class_key IS NULL)
    UNION ALL SELECT 'I07', 'dim_depth_class', 'depth_class_key',
           (SELECT count(*) FROM fact_seismic_event f LEFT JOIN dim_depth_class d USING (depth_class_key) WHERE d.depth_class_key IS NULL)
) o;

-- I08 the physical FK constraints exist (the database itself enforces integrity)
INSERT INTO dq_check_result (run_id, check_code, category, check_name, target_object, expected_value, actual_value, status, details)
SELECT (SELECT run_id FROM _dq), 'I08', 'INTEGRITY', 'Declared FOREIGN KEY constraints on the fact table',
       'fact_seismic_event', 7, n, CASE WHEN n = 7 THEN 'PASS' ELSE 'FAIL' END, 'pg_constraint contype = f'
FROM (SELECT count(*) AS n FROM pg_constraint
      WHERE conrelid = 'project_dw.fact_seismic_event'::regclass AND contype = 'f') x;

-- I09 rows mapped to an Unknown (-1) member - INFO (legitimately NULL source attributes)
INSERT INTO dq_check_result (run_id, check_code, category, check_name, target_object, expected_value, actual_value, status, details)
SELECT (SELECT run_id FROM _dq), 'I09', 'INTEGRITY', 'Fact rows mapped to an Unknown (-1) member',
       'fact_seismic_event', NULL, n, 'INFO', d
FROM (SELECT count(*) AS n,
             format('location=%s network=%s magnitude_type=%s event_type=%s',
                    count(*) FILTER (WHERE location_key = -1), count(*) FILTER (WHERE network_key = -1),
                    count(*) FILTER (WHERE magnitude_type_key = -1), count(*) FILTER (WHERE event_type_key = -1)) AS d
      FROM fact_seismic_event
      WHERE -1 IN (location_key, network_key, magnitude_type_key, event_type_key, magnitude_class_key, depth_class_key)) x;

/* ===================== UNIQUENESS ======================================= */

INSERT INTO dq_check_result (run_id, check_code, category, check_name, target_object, expected_value, actual_value, status, details)
SELECT (SELECT run_id FROM _dq), code, 'UNIQUENESS', 'Duplicate business keys: ' || obj, obj, 0, total - distinct_keys,
       CASE WHEN total = distinct_keys THEN 'PASS' ELSE 'FAIL' END,
       format('rows=%s distinct business keys=%s', total, distinct_keys)
FROM (
    SELECT 'U01' AS code, 'dim_date (full_date)' AS obj, count(*) AS total, count(DISTINCT full_date) AS distinct_keys FROM dim_date
    UNION ALL SELECT 'U02', 'dim_location (location_code)', count(*), count(DISTINCT location_code) FROM dim_location
    UNION ALL SELECT 'U03', 'dim_network (network_code, current versions - SCD2)', count(*) FILTER (WHERE is_current),
                     count(DISTINCT network_code) FROM dim_network
    UNION ALL SELECT 'U04', 'dim_magnitude_type (magnitude_type_code)', count(*), count(DISTINCT magnitude_type_code) FROM dim_magnitude_type
    UNION ALL SELECT 'U05', 'dim_event_type (event_type_code)', count(*), count(DISTINCT event_type_code) FROM dim_event_type
    UNION ALL SELECT 'U06', 'dim_magnitude_class (magnitude_class)', count(*), count(DISTINCT magnitude_class) FROM dim_magnitude_class
    UNION ALL SELECT 'U07', 'dim_depth_class (depth_class)', count(*), count(DISTINCT depth_class) FROM dim_depth_class
    UNION ALL SELECT 'U08', 'fact_seismic_event (event_id)', count(*), count(DISTINCT event_id) FROM fact_seismic_event
    UNION ALL SELECT 'U09', 'stg_seismic_event (batch_id, event_id)', count(*), count(DISTINCT (batch_id, event_id)) FROM stg_seismic_event
) u;

-- U10 the same physical earthquake must not be active under two ids
INSERT INTO dq_check_result (run_id, check_code, category, check_name, target_object, expected_value, actual_value, status, details)
SELECT (SELECT run_id FROM _dq), 'U10', 'UNIQUENESS', 'Active fact events that are an alias id of another active event',
       'fact_seismic_event (USGS ids association)', 0, n, CASE WHEN n = 0 THEN 'PASS' ELSE 'FAIL' END,
       'event_id listed in the associated ids of a different active event'
FROM (SELECT count(DISTINCT a.event_id) AS n
      FROM fact_seismic_event a
      JOIN (SELECT unnest(s.associated_ids) AS alias_id, p.event_id AS preferred_id
            FROM fact_seismic_event p
            JOIN stg_seismic_event s ON s.event_id = p.event_id AND s.batch_id = p.updated_batch_id
            WHERE p.is_active) al
        ON al.alias_id = a.event_id AND al.preferred_id <> a.event_id
      WHERE a.is_active) x;

/* ===================== CONSISTENCY ====================================== */

-- K01 magnitude / depth class agrees with the numeric value
INSERT INTO dq_check_result (run_id, check_code, category, check_name, target_object, expected_value, actual_value, status, details)
SELECT (SELECT run_id FROM _dq), 'K01', 'CONSISTENCY', 'Class band disagrees with magnitude or depth value',
       'fact_seismic_event', 0, n, CASE WHEN n = 0 THEN 'PASS' ELSE 'FAIL' END, NULL
FROM (SELECT count(*) AS n
      FROM fact_seismic_event f
      JOIN dim_magnitude_class mc USING (magnitude_class_key)
      JOIN dim_depth_class dc USING (depth_class_key)
      WHERE NOT (f.magnitude >= COALESCE(mc.min_magnitude, -99) AND f.magnitude < COALESCE(mc.max_magnitude, 99))
         OR NOT (f.depth_km  >= COALESCE(dc.min_depth_km, -9999) AND f.depth_km < COALESCE(dc.max_depth_km, 9999))) x;

-- K02 date_key agrees with event_time (UTC) and the date range is covered
INSERT INTO dq_check_result (run_id, check_code, category, check_name, target_object, expected_value, actual_value, status, details)
SELECT (SELECT run_id FROM _dq), 'K02', 'CONSISTENCY', 'date_key disagrees with event_time (UTC)',
       'fact_seismic_event', 0, n, CASE WHEN n = 0 THEN 'PASS' ELSE 'FAIL' END, NULL
FROM (SELECT count(*) AS n FROM fact_seismic_event
      WHERE date_key <> to_char(event_time AT TIME ZONE 'UTC', 'YYYYMMDD')::INT) x;

INSERT INTO dq_check_result (run_id, check_code, category, check_name, target_object, expected_value, actual_value, status, details)
SELECT (SELECT run_id FROM _dq), 'K03', 'CONSISTENCY', 'dim_date is contiguous and covers every event date',
       'dim_date', span, cnt, CASE WHEN span = cnt AND covered THEN 'PASS' ELSE 'FAIL' END,
       format('%s .. %s, %s rows; first event %s, last event %s', d_min, d_max, cnt, e_min, e_max)
FROM (SELECT min(full_date) AS d_min, max(full_date) AS d_max, count(*) AS cnt,
             (max(full_date) - min(full_date) + 1) AS span,
             (SELECT min(event_time AT TIME ZONE 'UTC')::DATE FROM fact_seismic_event) AS e_min,
             (SELECT max(event_time AT TIME ZONE 'UTC')::DATE FROM fact_seismic_event) AS e_max,
             (SELECT min(event_time AT TIME ZONE 'UTC')::DATE FROM fact_seismic_event) >= min(full_date)
             AND (SELECT max(event_time AT TIME ZONE 'UTC')::DATE FROM fact_seismic_event) <= max(full_date) AS covered
      FROM dim_date) x;

-- summary line in the step log
INSERT INTO etl_step_log (batch_id, step_name, target_table, rows_processed, note)
SELECT (SELECT run_id FROM _dq), 'data_quality', 'project_staging.dq_check_result', count(*),
       format('PASS=%s FAIL=%s INFO=%s', count(*) FILTER (WHERE status = 'PASS'),
              count(*) FILTER (WHERE status = 'FAIL'), count(*) FILTER (WHERE status = 'INFO'))
FROM dq_check_result
WHERE run_id = (SELECT run_id FROM _dq)
  AND run_started_at = now();
