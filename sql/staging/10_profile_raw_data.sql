/* ============================================================================
   10_profile_raw_data.sql  -  DATA PROFILING of the raw landing tables

   Reproducible queries that expose the source defects BEFORE cleaning
   (Lab 06 Task 4.3 / Lab 07 Task 2). They read raw_* only, so they show what
   actually arrived. Each query is tagged "-- name:" - etl/build_reports.py
   executes them and prints the results in the Data Cleaning Report.
   ============================================================================ */

SET search_path TO project_staging, public;

-- name: raw_rows_per_batch
-- Baseline row counts recorded immediately after loading
SELECT b.batch_id, b.source_file, b.load_type, b.is_rerun, count(r.raw_id) AS raw_rows
FROM etl_batch b
LEFT JOIN raw_usgs_event r USING (batch_id)
WHERE b.source_name = 'usgs_events'
GROUP BY b.batch_id, b.source_file, b.load_type, b.is_rerun
ORDER BY b.batch_id;

-- name: duplicate_event_ids
-- Duplicate business keys: same event_id inside one batch / across batches
SELECT 'within the same batch' AS scope,
       count(*) AS duplicated_event_ids
FROM (SELECT batch_id, feature ->> 'id' FROM raw_usgs_event GROUP BY 1, 2 HAVING count(*) > 1) x
UNION ALL
SELECT 'across batches (event_id delivered more than once)',
       count(*)
FROM (SELECT feature ->> 'id' FROM raw_usgs_event GROUP BY 1 HAVING count(DISTINCT batch_id) > 1) y
UNION ALL
SELECT 'across batches, excluding the deliberate re-run batch',
       count(*)
FROM (SELECT r.feature ->> 'id' FROM raw_usgs_event r JOIN etl_batch b USING (batch_id)
      WHERE NOT b.is_rerun GROUP BY 1 HAVING count(DISTINCT r.batch_id) > 1) z;

-- name: duplicate_versions
-- For cross-batch duplicates: identical copy vs different USGS version
SELECT duplicate_kind, count(*) AS event_ids
FROM (
    SELECT CASE WHEN count(DISTINCT record_hash) = 1 THEN 'identical copies (same hash)'
                ELSE 'different versions (hash differs)' END AS duplicate_kind
    FROM (SELECT r.feature ->> 'id' AS event_id, r.record_hash
          FROM raw_usgs_event r JOIN etl_batch b USING (batch_id) WHERE NOT b.is_rerun) t
    GROUP BY event_id
    HAVING count(*) > 1
) k
GROUP BY duplicate_kind
ORDER BY 1;

-- name: merged_event_ids
-- Same earthquake, two ids: an event_id listed in the USGS "ids" of a different event
SELECT count(DISTINCT a.event_id) AS alias_ids_delivered_as_separate_events
FROM v_raw_usgs_event_flat a
JOIN (SELECT feature ->> 'id' AS preferred_id,
             unnest(string_to_array(btrim(feature -> 'properties' ->> 'ids', ','), ',')) AS alias_id
      FROM raw_usgs_event) p
  ON p.alias_id = a.event_id AND p.preferred_id <> a.event_id;

-- name: null_profile
-- NULL / missing values per source attribute (all raw rows)
SELECT attribute, null_rows, total_rows, round(100.0 * null_rows / total_rows, 2) AS null_pct
FROM (
    SELECT 'event_id' AS attribute, count(*) FILTER (WHERE event_id IS NULL) AS null_rows, count(*) AS total_rows, 1 AS o FROM v_raw_usgs_event_flat
    UNION ALL SELECT 'time',     count(*) FILTER (WHERE time_ms IS NULL), count(*), 2 FROM v_raw_usgs_event_flat
    UNION ALL SELECT 'mag',      count(*) FILTER (WHERE mag IS NULL), count(*), 3 FROM v_raw_usgs_event_flat
    UNION ALL SELECT 'magType',  count(*) FILTER (WHERE mag_type IS NULL), count(*), 4 FROM v_raw_usgs_event_flat
    UNION ALL SELECT 'place',    count(*) FILTER (WHERE place IS NULL), count(*), 5 FROM v_raw_usgs_event_flat
    UNION ALL SELECT 'status',   count(*) FILTER (WHERE status IS NULL), count(*), 6 FROM v_raw_usgs_event_flat
    UNION ALL SELECT 'depth',    count(*) FILTER (WHERE depth IS NULL), count(*), 7 FROM v_raw_usgs_event_flat
    UNION ALL SELECT 'felt',     count(*) FILTER (WHERE felt IS NULL), count(*), 8 FROM v_raw_usgs_event_flat
    UNION ALL SELECT 'cdi',      count(*) FILTER (WHERE cdi IS NULL), count(*), 9 FROM v_raw_usgs_event_flat
    UNION ALL SELECT 'mmi',      count(*) FILTER (WHERE mmi IS NULL), count(*), 10 FROM v_raw_usgs_event_flat
    UNION ALL SELECT 'alert',    count(*) FILTER (WHERE alert IS NULL), count(*), 11 FROM v_raw_usgs_event_flat
    UNION ALL SELECT 'nst',      count(*) FILTER (WHERE nst IS NULL), count(*), 12 FROM v_raw_usgs_event_flat
    UNION ALL SELECT 'gap',      count(*) FILTER (WHERE gap IS NULL), count(*), 13 FROM v_raw_usgs_event_flat
) p
ORDER BY o;

-- name: whitespace_issues
-- Leading / trailing / repeated whitespace in descriptive text
SELECT 'place' AS attribute,
       count(*) FILTER (WHERE place <> btrim(place)) AS leading_or_trailing,
       count(*) FILTER (WHERE place ~ '\s{2,}')       AS repeated_internal
FROM v_raw_usgs_event_flat
UNION ALL
SELECT 'network_name (ref CSV)', count(*) FILTER (WHERE network_name <> btrim(network_name)),
       count(*) FILTER (WHERE network_name ~ '\s{2,}')
FROM raw_seismic_network;

-- name: whitespace_examples
SELECT DISTINCT '"' || place || '"' AS raw_place_with_quotes, '"' || project_staging.fn_clean_text(place) || '"' AS cleaned
FROM v_raw_usgs_event_flat
WHERE place <> btrim(place) OR place ~ '\s{2,}'
LIMIT 8;

-- name: inconsistent_area_spellings
-- One real place, several spellings in the trailing "area" token of place
SELECT area_token, count(*) AS raw_rows
FROM (SELECT CASE WHEN place LIKE '%,%' THEN btrim(regexp_replace(place, '^.*,', '')) ELSE place END AS area_token
      FROM v_raw_usgs_event_flat) t
WHERE area_token IN ('CA', 'California', 'California Earthquake', 'NV', 'Nevada', 'MX', 'Mexico', 'B.C.',
                     'Japan', 'Japan region', 'Fiji', 'Fiji region', 'south of the Fiji Islands',
                     'Burma (Myanmar)', 'Myanmar', 'Timor Leste',
                     'northern Mid-Atlantic Ridge', 'central Mid-Atlantic Ridge', 'southern Mid-Atlantic Ridge')
GROUP BY area_token
ORDER BY area_token;

-- name: distinct_area_tokens
-- Cardinality of the raw area token vs the conformed location after cleaning
SELECT (SELECT count(DISTINCT CASE WHEN place LIKE '%,%' THEN btrim(regexp_replace(place, '^.*,', '')) ELSE place END)
        FROM v_raw_usgs_event_flat) AS distinct_raw_area_tokens,
       (SELECT count(DISTINCT location_code) FROM stg_seismic_event) AS distinct_conformed_locations;

-- name: code_values
-- Distribution of coded attributes (case / NULL check)
SELECT 'magType' AS attribute, COALESCE(mag_type, '<NULL>') AS value, count(*) AS raw_rows FROM v_raw_usgs_event_flat GROUP BY 2
UNION ALL SELECT 'type', COALESCE(event_type, '<NULL>'), count(*) FROM v_raw_usgs_event_flat GROUP BY 2
UNION ALL SELECT 'status', COALESCE(status, '<NULL>'), count(*) FROM v_raw_usgs_event_flat GROUP BY 2
UNION ALL SELECT 'alert', COALESCE(alert, '<NULL>'), count(*) FROM v_raw_usgs_event_flat GROUP BY 2
ORDER BY 1, 3 DESC;

-- name: network_codes_not_in_reference
-- Event network codes missing from the reference CSV (become inferred dimension members)
SELECT lower(btrim(f.net)) AS network_code, count(*) AS raw_rows
FROM v_raw_usgs_event_flat f
WHERE NOT EXISTS (SELECT 1 FROM raw_seismic_network n WHERE lower(btrim(n.network_code)) = lower(btrim(f.net)))
GROUP BY 1 ORDER BY 2 DESC;

-- name: range_violations
-- Values outside the valid domain (rule used by the staging validation)
SELECT 'latitude outside [-90, 90]' AS rule, count(*) FILTER (WHERE latitude::NUMERIC NOT BETWEEN -90 AND 90) AS raw_rows FROM v_raw_usgs_event_flat
UNION ALL SELECT 'longitude outside [-180, 180]', count(*) FILTER (WHERE longitude::NUMERIC NOT BETWEEN -180 AND 180) FROM v_raw_usgs_event_flat
UNION ALL SELECT 'magnitude outside [-2, 10]', count(*) FILTER (WHERE mag::NUMERIC NOT BETWEEN -2 AND 10) FROM v_raw_usgs_event_flat
UNION ALL SELECT 'depth outside [-10, 800] km', count(*) FILTER (WHERE depth::NUMERIC NOT BETWEEN -10 AND 800) FROM v_raw_usgs_event_flat
UNION ALL SELECT 'negative depth (valid: above datum)', count(*) FILTER (WHERE depth::NUMERIC < 0) FROM v_raw_usgs_event_flat
UNION ALL SELECT 'magnitude with > 2 decimals', count(*) FILTER (WHERE mag ~ '\.\d{3,}') FROM v_raw_usgs_event_flat
UNION ALL SELECT 'epoch-millisecond timestamps to convert', count(*) FILTER (WHERE time_ms IS NOT NULL) FROM v_raw_usgs_event_flat;

-- name: type_conversion_examples
SELECT event_id, time_ms AS raw_time_epoch_ms,
       to_char(project_staging.fn_epoch_ms_to_ts(time_ms) AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS.MS') || ' UTC' AS converted_timestamptz,
       mag AS raw_mag_text, round(project_staging.fn_try_numeric(mag), 2) AS converted_numeric_4_2,
       depth AS raw_depth_text, round(project_staging.fn_try_numeric(depth), 3) AS converted_numeric_8_3
FROM v_raw_usgs_event_flat
WHERE mag ~ '\.\d{3,}' AND depth ~ '\.\d{4,}'
LIMIT 5;
