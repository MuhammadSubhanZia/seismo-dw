/* ============================================================================
   12_clean_events_to_staging.sql  -  ETL (T): raw_usgs_event -> stg_seismic_event

   Part of deliverable "ETL Scripts SQL/Python".  ELT style: the raw GeoJSON is already
   inside PostgreSQL (raw_usgs_event); all cleaning happens here in SQL.

   Processes ONE batch: the value of the session setting etl.batch_id
   (the Python orchestrator sets it; in pgAdmin run
        SELECT set_config('etl.batch_id', '<id>', false);
   first, or leave it unset to process the newest RAW_LOADED events batch).

   Transformations (Phase 2, section 3):
     1. Convert data types     epoch ms -> TIMESTAMPTZ, JSON text -> NUMERIC/INT/BOOLEAN
     2. Validate               required fields + valid ranges -> rejected_event (quarantine)
     3. Remove duplicates      one row per event_id per batch (latest USGS "updated" wins);
                               superseded copies logged as DUPLICATE_IN_BATCH.
                               Cross-batch duplicates are resolved by the fact load
                               (only a NEWER version may update the warehouse), and
                               "same earthquake, different id" duplicates are detected
                               through the USGS ids list kept in associated_ids.
     4. Handle NULL values     felt -> 0, alert -> 'none', status -> 'unknown',
                               sig -> 0, tsunami -> FALSE; cdi/mmi/nst/gap stay NULL
                               (not measured != zero); NULL magType/net/type -> Unknown member.
     5. Standardise text       TRIM/whitespace collapse, codes lower-case, and the
                               free-text place is conformed:
                                 "CA" / "California" / " California "  -> United States, California
                                 "MX" / "B.C., MX"                    -> Mexico
                                 "Japan region"                       -> Japan
                                 "south of the Fiji Islands"          -> Fiji Islands
                                 "2025 Drake Passage Earthquake"      -> Drake Passage (named-event prefix)
   ============================================================================ */

SET search_path TO project_staging, public;

DROP TABLE IF EXISTS pg_temp._ctx;
CREATE TEMP TABLE _ctx AS
SELECT COALESCE(
         NULLIF(current_setting('etl.batch_id', true), '')::BIGINT,
         (SELECT max(batch_id) FROM etl_batch WHERE source_name = 'usgs_events' AND status = 'RAW_LOADED')
       ) AS batch_id;

/* ---- STEP 1: parse JSON + convert data types ---------------------------- */
DROP TABLE IF EXISTS pg_temp._parsed;
CREATE TEMP TABLE _parsed AS
SELECT r.raw_id,
       r.batch_id,
       r.source_row_num,
       r.record_hash,
       fn_clean_text(r.feature ->> 'id')                     AS event_id,
       -- ",aka2026simkls,us6000ty7h," -> {aka2026simkls,us6000ty7h}: ids USGS merged into this event
       COALESCE(string_to_array(NULLIF(btrim(p ->> 'ids', ', '), ''), ','),
                ARRAY[fn_clean_text(r.feature ->> 'id')])     AS associated_ids,
       fn_epoch_ms_to_ts(p ->> 'time')                       AS event_time,
       fn_epoch_ms_to_ts(p ->> 'updated')                    AS source_updated_at,
       round(fn_try_numeric(p ->> 'mag'), 2)                 AS magnitude,
       lower(fn_clean_text(p ->> 'magType'))                 AS magnitude_type,
       round(fn_try_numeric(c ->> 2), 3)                     AS depth_km,
       round(fn_try_numeric(c ->> 1), 6)                     AS latitude,
       round(fn_try_numeric(c ->> 0), 6)                     AS longitude,
       fn_clean_text(p ->> 'place')                          AS place,
       lower(fn_clean_text(p ->> 'net'))                     AS network_code,
       lower(fn_clean_text(p ->> 'type'))                    AS event_type,
       lower(fn_clean_text(p ->> 'status'))                  AS status_raw,
       lower(fn_clean_text(p ->> 'alert'))                   AS alert_raw,
       fn_try_numeric(p ->> 'tsunami')                       AS tsunami_raw,
       fn_try_numeric(p ->> 'felt')::INT                     AS felt_raw,
       round(fn_try_numeric(p ->> 'cdi'), 2)                 AS cdi,
       round(fn_try_numeric(p ->> 'mmi'), 3)                 AS mmi,
       fn_try_numeric(p ->> 'sig')::INT                      AS sig_raw,
       fn_try_numeric(p ->> 'nst')::INT                      AS station_count,
       round(fn_try_numeric(p ->> 'gap'), 2)                 AS azimuthal_gap,
       round(fn_try_numeric(p ->> 'rms'), 4)                 AS rms_residual,
       round(fn_try_numeric(p ->> 'dmin'), 4)                AS min_distance_deg,
       CAST(NULL AS TEXT)                                    AS reject_reason
FROM raw_usgs_event r
CROSS JOIN LATERAL (SELECT r.feature -> 'properties' AS p,
                           r.feature -> 'geometry' -> 'coordinates' AS c) j
WHERE r.batch_id = (SELECT batch_id FROM _ctx);

/* ---- STEP 2: validation rules (first failing rule is recorded) ---------- */
UPDATE _parsed SET reject_reason = CASE
    WHEN event_id IS NULL                                        THEN 'MISSING_EVENT_ID'
    WHEN event_time IS NULL                                      THEN 'MISSING_EVENT_TIME'
    WHEN source_updated_at IS NULL                               THEN 'MISSING_UPDATED_TIME'
    WHEN latitude IS NULL OR longitude IS NULL                   THEN 'MISSING_COORDINATES'
    WHEN latitude NOT BETWEEN -90 AND 90
      OR longitude NOT BETWEEN -180 AND 180                      THEN 'INVALID_COORDINATES'
    WHEN magnitude IS NULL                                       THEN 'MISSING_MAGNITUDE'
    WHEN magnitude NOT BETWEEN -2 AND 10                         THEN 'INVALID_MAGNITUDE'
    WHEN depth_km IS NULL                                        THEN 'MISSING_DEPTH'
    WHEN depth_km NOT BETWEEN -10 AND 800                        THEN 'INVALID_DEPTH'
    WHEN event_time > now() + INTERVAL '1 day'                   THEN 'FUTURE_EVENT_TIME'
END;

INSERT INTO rejected_event (batch_id, raw_id, event_id, stage, reason_code, reason_detail)
SELECT batch_id, raw_id, event_id, 'STAGING', reject_reason,
       format('mag=%s depth=%s lat=%s lon=%s time=%s status=%s',
              magnitude, depth_km, latitude, longitude, event_time, status_raw)
FROM _parsed
WHERE reject_reason IS NOT NULL
ON CONFLICT (batch_id, raw_id, stage) DO NOTHING;

/* ---- STEP 3: remove duplicates inside the batch ------------------------- */
DROP TABLE IF EXISTS pg_temp._ranked;
CREATE TEMP TABLE _ranked AS
SELECT p.*,
       row_number() OVER (PARTITION BY event_id
                          ORDER BY source_updated_at DESC, source_row_num DESC) AS rn
FROM _parsed p
WHERE reject_reason IS NULL;

INSERT INTO rejected_event (batch_id, raw_id, event_id, stage, reason_code, reason_detail)
SELECT batch_id, raw_id, event_id, 'STAGING', 'DUPLICATE_IN_BATCH',
       'superseded by a newer copy of the same event_id in this batch'
FROM _ranked
WHERE rn > 1
ON CONFLICT (batch_id, raw_id, stage) DO NOTHING;

/* ---- STEP 4: NULL handling + text standardisation + location conformance */
DROP TABLE IF EXISTS pg_temp._clean;
CREATE TEMP TABLE _clean AS
WITH base AS (
    SELECT d.*,
           -- token after the last comma is the country / state / ocean area
           CASE WHEN d.place LIKE '%,%' THEN btrim(regexp_replace(d.place, '^.*,', '')) ELSE d.place END AS area_raw,
           CASE WHEN d.place LIKE '%,%' THEN btrim(split_part(d.place, ',', 1))          ELSE d.place END AS region_raw
    FROM _ranked d
    WHERE d.rn = 1
), conformed AS (
    SELECT b.*,
           btrim(regexp_replace(
             regexp_replace(
               regexp_replace(
                 regexp_replace(regexp_replace(COALESCE(b.area_raw, ''),
                   '^(19|20)[0-9]{2}\s+', ''),                                      -- "2025 Drake Passage Earthquake"
                   '^(.*\s)?(north|south|east|west|northeast|northwest|southeast|southwest|northern|southern|eastern|western|central)\s+of\s+(the\s+)?', '', 'i'),
                 '^(off|near)\s+the\s+(.*\s+)?coast\s+of\s+(the\s+)?', '', 'i'),
               '^((northern|southern|eastern|western|central)\s+)+', ''),          -- lower-case USGS qualifiers only
             '\s+(region|earthquake)$', '', 'i')) AS area
    FROM base b
), resolved AS (
    SELECT c.*,
           s.state_name,
           a.country AS alias_country
    FROM conformed c
    LEFT JOIN stg_us_state s
           ON upper(c.area) = s.state_code
           OR (s.match_by_name AND upper(c.area) = upper(s.state_name))
    LEFT JOIN stg_country_alias a
           ON a.alias_upper = upper(c.area)
)
SELECT r.*,
       CASE WHEN r.area = ''               THEN 'Unknown'
            WHEN r.state_name IS NOT NULL  THEN 'United States'
            WHEN r.alias_country IS NOT NULL THEN r.alias_country
            ELSE r.area END                                            AS country,
       COALESCE(r.state_name, 'N/A')                                   AS state_province,
       CASE WHEN r.state_name IS NOT NULL  THEN 'United States'
            WHEN r.area = ''               THEN 'Unknown'
            WHEN r.area ~* '(ridge|rise|ocean|\msea\M|trench|basin|gulf|strait|passage|fracture zone|triple junction)'
                                           THEN 'Oceanic / Remote'
            ELSE 'Country / Territory' END                             AS location_type,
       btrim(regexp_replace(COALESCE(r.region_raw, r.place),
             '^[0-9.]+\s*km\s+[NSEW]{1,3}\s+of\s+', ''))               AS nearest_place
FROM resolved r;

/* ---- STEP 5: write the cleaned batch ------------------------------------ */
WITH ins AS (
    INSERT INTO stg_seismic_event (
        batch_id, event_id, associated_ids, raw_id, event_time, source_updated_at, magnitude, magnitude_type,
        depth_km, latitude, longitude, place, nearest_place, country, state_province,
        location_type, location_code, network_code, event_type, review_status, alert_level,
        tsunami_flag, felt_reports, cdi, mmi, significance, station_count, azimuthal_gap,
        rms_residual, min_distance_deg, is_active, record_hash)
    SELECT batch_id, event_id, associated_ids, raw_id, event_time, source_updated_at, magnitude, magnitude_type,
           depth_km, latitude, longitude, place, nearest_place, country, state_province,
           location_type,
           CASE WHEN country = 'Unknown' THEN NULL
                ELSE btrim(upper(regexp_replace(country, '[^A-Za-z0-9]+', '_', 'g')), '_')
                     || CASE WHEN state_province <> 'N/A'
                             THEN ':' || btrim(upper(regexp_replace(state_province, '[^A-Za-z0-9]+', '_', 'g')), '_')
                             ELSE '' END
           END                                          AS location_code,
           network_code,
           event_type,
           COALESCE(status_raw, 'unknown')              AS review_status,
           COALESCE(alert_raw, 'none')                  AS alert_level,
           COALESCE(tsunami_raw = 1, FALSE)             AS tsunami_flag,
           COALESCE(felt_raw, 0)                        AS felt_reports,
           cdi, mmi,
           COALESCE(sig_raw, 0)                         AS significance,
           station_count, azimuthal_gap, rms_residual, min_distance_deg,
           COALESCE(status_raw, 'unknown') <> 'deleted' AS is_active,
           record_hash
    FROM _clean
    ON CONFLICT (batch_id, event_id) DO NOTHING
    RETURNING 1
)
INSERT INTO etl_step_log (batch_id, step_name, target_table, rows_processed, rows_inserted, rows_rejected, note)
SELECT (SELECT batch_id FROM _ctx), 'clean_events', 'project_staging.stg_seismic_event',
       (SELECT count(*) FROM _parsed),
       (SELECT count(*) FROM ins),
       (SELECT count(*) FROM _parsed WHERE reject_reason IS NOT NULL)
         + (SELECT count(*) FROM _ranked WHERE rn > 1),
       format('validation rejects=%s, in-batch duplicates=%s',
              (SELECT count(*) FROM _parsed WHERE reject_reason IS NOT NULL),
              (SELECT count(*) FROM _ranked WHERE rn > 1));

UPDATE etl_batch
   SET rows_staged    = (SELECT count(*) FROM stg_seismic_event WHERE batch_id = (SELECT batch_id FROM _ctx)),
       rows_duplicate = (SELECT count(*) FROM _ranked WHERE rn > 1),
       rows_rejected  = (SELECT count(*) FROM rejected_event
                         WHERE batch_id = (SELECT batch_id FROM _ctx) AND stage = 'STAGING')
 WHERE batch_id = (SELECT batch_id FROM _ctx);
