/* ============================================================================
   30_load_fact_seismic_event.sql  -  FACT LOAD: fact_seismic_event

   Deliverable: "Fact Load Scripts SQL"

   Business key -> surrogate key mapping (Phase 2, section 5):

        USGS GeoJSON            stg_seismic_event              dimensions                  fact_seismic_event
        place "..., CA"   ->   location_code                -> dim_location.location_key -> location_key = 10xx
                               'UNITED_STATES:CALIFORNIA'
        net  "ak"         ->   network_code 'ak'            -> dim_network.network_key   -> network_key  = 10xx
        time 1735689600000->   event_time 2025-01-01 00:00Z -> dim_date.date_key         -> date_key     = 20250101
        mag  4.7          ->   magnitude 4.70               -> dim_magnitude_class (range join) -> magnitude_class_key

   Rules
   - Dimensions are loaded BEFORE this script (Lab 06 "dimensions before facts").
   - The INSERT stores surrogate keys only; business codes never reach the fact.
   - A NULL source attribute maps to the Unknown member (-1). A NON-NULL business key
     that has no dimension row is REJECTED to rejected_event (UNMAPPED_*), never
     silently dropped and never hidden behind -1 (Lab 07 Task 3).
   - Idempotent upsert on the degenerate key event_id:
        new event                     -> INSERT
        same event, newer USGS version-> UPDATE (source_updated_at guard)
        same event, same/older version-> no change   (re-running a batch changes 0 rows)
   - USGS status 'deleted' -> soft delete (is_active = FALSE) of an existing fact row;
     a deletion for an event that was never loaded is rejected (DELETED_EVENT_NOT_IN_DW).
   - Same earthquake under two ids (USGS merges ids into a preferred id and lists them in
     "ids"): an alias id arriving after its preferred event is rejected (SUPERSEDED_EVENT_ID);
     a preferred event arriving after its alias deactivates the alias row (review_status
     'superseded'), so each physical earthquake is counted once.
   ============================================================================ */

SET search_path TO project_dw, project_staging, public;

DROP TABLE IF EXISTS pg_temp._fctx;
CREATE TEMP TABLE _fctx AS
SELECT COALESCE(
         NULLIF(current_setting('etl.batch_id', true), '')::BIGINT,
         (SELECT max(batch_id) FROM project_staging.etl_batch WHERE source_name = 'usgs_events' AND status = 'RAW_LOADED')
       ) AS batch_id;

/* ---- STEP 1: map every business key of the batch to its surrogate key ---- */
DROP TABLE IF EXISTS pg_temp._mapped;
CREATE TEMP TABLE _mapped AS
SELECT s.*,
       d.date_key,
       CASE WHEN s.location_code  IS NULL THEN -1 ELSE l.location_key       END AS location_key,
       CASE WHEN s.network_code   IS NULL THEN -1 ELSE n.network_key        END AS network_key,
       CASE WHEN s.magnitude_type IS NULL THEN -1 ELSE mt.magnitude_type_key END AS magnitude_type_key,
       CASE WHEN s.event_type     IS NULL THEN -1 ELSE et.event_type_key     END AS event_type_key,
       COALESCE(mc.magnitude_class_key, -1)                                    AS magnitude_class_key,
       COALESCE(dc.depth_class_key, -1)                                        AS depth_class_key,
       power(10::DOUBLE PRECISION, 1.5 * s.magnitude::DOUBLE PRECISION + 4.8) AS energy_joules
FROM project_staging.stg_seismic_event s
LEFT JOIN project_dw.dim_date d
       ON d.date_key = to_char(s.event_time AT TIME ZONE 'UTC', 'YYYYMMDD')::INT
LEFT JOIN project_dw.dim_location l
       ON l.location_code = s.location_code
LEFT JOIN project_dw.dim_network n
       ON n.network_code = s.network_code
LEFT JOIN project_dw.dim_magnitude_type mt
       ON mt.magnitude_type_code = s.magnitude_type
LEFT JOIN project_dw.dim_event_type et
       ON et.event_type_code = s.event_type
LEFT JOIN project_dw.dim_magnitude_class mc
       ON mc.magnitude_class_key <> -1
      AND s.magnitude >= COALESCE(mc.min_magnitude, -99)
      AND s.magnitude <  COALESCE(mc.max_magnitude,  99)
LEFT JOIN project_dw.dim_depth_class dc
       ON dc.depth_class_key <> -1
      AND s.depth_km >= COALESCE(dc.min_depth_km, -9999)
      AND s.depth_km <  COALESCE(dc.max_depth_km,  9999)
WHERE s.batch_id = (SELECT batch_id FROM _fctx);

/* ---- STEP 2: reject unmapped business keys, orphan deletions, superseded ids */

-- alias id -> preferred id pairs known from the warehouse and from this batch
DROP TABLE IF EXISTS pg_temp._alias;
CREATE TEMP TABLE _alias AS
SELECT DISTINCT alias_id, preferred_id
FROM (
    SELECT unnest(s2.associated_ids) AS alias_id, s2.event_id AS preferred_id
    FROM project_dw.fact_seismic_event f2
    JOIN project_staging.stg_seismic_event s2
      ON s2.event_id = f2.event_id AND s2.batch_id = f2.updated_batch_id
    UNION ALL
    SELECT unnest(associated_ids), event_id FROM _mapped
) a
WHERE alias_id <> preferred_id;
CREATE INDEX ON _alias (alias_id);
ANALYZE _alias;

DROP TABLE IF EXISTS pg_temp._fact_rejects;
CREATE TEMP TABLE _fact_rejects AS
SELECT m.batch_id, m.raw_id, m.event_id,
       CASE WHEN m.date_key IS NULL           THEN 'UNMAPPED_DATE'
            WHEN m.location_key IS NULL       THEN 'UNMAPPED_LOCATION'
            WHEN m.network_key IS NULL        THEN 'UNMAPPED_NETWORK'
            WHEN m.magnitude_type_key IS NULL THEN 'UNMAPPED_MAGNITUDE_TYPE'
            WHEN m.event_type_key IS NULL     THEN 'UNMAPPED_EVENT_TYPE'
            WHEN NOT m.is_active
             AND NOT EXISTS (SELECT 1 FROM project_dw.fact_seismic_event f WHERE f.event_id = m.event_id)
                                              THEN 'DELETED_EVENT_NOT_IN_DW'
            -- same earthquake already loaded under its preferred id: USGS lists this id among
            -- the associated ids of a DIFFERENT event (in the warehouse or in this batch)
            WHEN EXISTS (SELECT 1 FROM _alias a WHERE a.alias_id = m.event_id)
                                              THEN 'SUPERSEDED_EVENT_ID'
       END AS reason_code,
       format('date=%s location=%s network=%s magtype=%s type=%s status=%s',
              to_char(m.event_time AT TIME ZONE 'UTC', 'YYYY-MM-DD'), m.location_code, m.network_code,
              m.magnitude_type, m.event_type, m.review_status) AS reason_detail
FROM _mapped m;
DELETE FROM _fact_rejects WHERE reason_code IS NULL;

INSERT INTO project_staging.rejected_event (batch_id, raw_id, event_id, stage, reason_code, reason_detail)
SELECT batch_id, raw_id, event_id, 'FACT_LOAD', reason_code, reason_detail FROM _fact_rejects
ON CONFLICT (batch_id, raw_id, stage) DO NOTHING;

DELETE FROM _mapped m USING _fact_rejects r WHERE m.event_id = r.event_id;

/* ---- STEP 3: soft deletes (USGS status = deleted, newer than the warehouse) */
DROP TABLE IF EXISTS pg_temp._soft_deleted;
CREATE TEMP TABLE _soft_deleted AS
WITH upd AS (
    UPDATE project_dw.fact_seismic_event f
       SET is_active         = FALSE,
           review_status     = m.review_status,
           source_updated_at = m.source_updated_at,
           updated_batch_id  = m.batch_id,
           dw_updated_at     = now()
      FROM _mapped m
     WHERE m.event_id = f.event_id
       AND NOT m.is_active
       AND m.source_updated_at > f.source_updated_at
    RETURNING f.event_id
)
SELECT * FROM upd;

/* ---- STEP 4: idempotent upsert of active events -------------------------- */
DROP TABLE IF EXISTS pg_temp._upserted;
CREATE TEMP TABLE _upserted AS
WITH up AS (
    INSERT INTO project_dw.fact_seismic_event AS f (
        event_id, date_key, location_key, network_key, magnitude_type_key, event_type_key,
        magnitude_class_key, depth_class_key, event_time, event_hour_utc, latitude, longitude,
        place, nearest_place, review_status, alert_level, tsunami_flag, is_significant, is_active,
        magnitude, depth_km, energy_joules, energy_tnt_tons, felt_reports, cdi, mmi, significance,
        station_count, azimuthal_gap, rms_residual, min_distance_deg, event_count,
        source_updated_at, inserted_batch_id, updated_batch_id)
    SELECT m.event_id, m.date_key, m.location_key, m.network_key, m.magnitude_type_key, m.event_type_key,
           m.magnitude_class_key, m.depth_class_key, m.event_time,
           EXTRACT(HOUR FROM m.event_time AT TIME ZONE 'UTC')::SMALLINT,
           m.latitude, m.longitude, m.place, m.nearest_place, m.review_status, m.alert_level,
           m.tsunami_flag, m.significance >= 600, TRUE,
           m.magnitude, m.depth_km, m.energy_joules, m.energy_joules / 4.184e9, m.felt_reports,
           m.cdi, m.mmi, m.significance, m.station_count, m.azimuthal_gap, m.rms_residual,
           m.min_distance_deg, 1, m.source_updated_at, m.batch_id, m.batch_id
    FROM _mapped m
    WHERE m.is_active
    ON CONFLICT (event_id) DO UPDATE SET
        date_key            = EXCLUDED.date_key,
        location_key        = EXCLUDED.location_key,
        network_key         = EXCLUDED.network_key,
        magnitude_type_key  = EXCLUDED.magnitude_type_key,
        event_type_key      = EXCLUDED.event_type_key,
        magnitude_class_key = EXCLUDED.magnitude_class_key,
        depth_class_key     = EXCLUDED.depth_class_key,
        event_time          = EXCLUDED.event_time,
        event_hour_utc      = EXCLUDED.event_hour_utc,
        latitude            = EXCLUDED.latitude,
        longitude           = EXCLUDED.longitude,
        place               = EXCLUDED.place,
        nearest_place       = EXCLUDED.nearest_place,
        review_status       = EXCLUDED.review_status,
        alert_level         = EXCLUDED.alert_level,
        tsunami_flag        = EXCLUDED.tsunami_flag,
        is_significant      = EXCLUDED.is_significant,
        is_active           = TRUE,
        magnitude           = EXCLUDED.magnitude,
        depth_km            = EXCLUDED.depth_km,
        energy_joules       = EXCLUDED.energy_joules,
        energy_tnt_tons     = EXCLUDED.energy_tnt_tons,
        felt_reports        = EXCLUDED.felt_reports,
        cdi                 = EXCLUDED.cdi,
        mmi                 = EXCLUDED.mmi,
        significance        = EXCLUDED.significance,
        station_count       = EXCLUDED.station_count,
        azimuthal_gap       = EXCLUDED.azimuthal_gap,
        rms_residual        = EXCLUDED.rms_residual,
        min_distance_deg    = EXCLUDED.min_distance_deg,
        source_updated_at   = EXCLUDED.source_updated_at,
        updated_batch_id    = EXCLUDED.updated_batch_id,
        dw_updated_at       = now()
    WHERE EXCLUDED.source_updated_at > f.source_updated_at      -- only a NEWER USGS version wins
    RETURNING (xmax = 0) AS inserted
)
SELECT * FROM up;

/* ---- STEP 4b: reverse case - a preferred event arrives AFTER its alias id was loaded:
               deactivate the alias row so the earthquake is counted once ------------------ */
DROP TABLE IF EXISTS pg_temp._superseded;
CREATE TEMP TABLE _superseded AS
WITH upd AS (
    UPDATE project_dw.fact_seismic_event f
       SET is_active        = FALSE,
           review_status    = 'superseded',
           updated_batch_id = (SELECT batch_id FROM _fctx),
           dw_updated_at    = now()
      FROM (SELECT DISTINCT unnest(associated_ids) AS alias_id, event_id AS preferred_id
            FROM _mapped WHERE is_active) a
     WHERE f.event_id = a.alias_id
       AND f.event_id <> a.preferred_id
       AND f.is_active
    RETURNING f.event_id
)
SELECT * FROM upd;

/* ---- STEP 5: log, watermark, batch status -------------------------------- */
INSERT INTO project_staging.etl_step_log
       (batch_id, step_name, target_table, rows_processed, rows_inserted, rows_updated, rows_rejected, note)
SELECT (SELECT batch_id FROM _fctx), 'load_fact', 'project_dw.fact_seismic_event',
       (SELECT count(*) FROM project_staging.stg_seismic_event WHERE batch_id = (SELECT batch_id FROM _fctx)),
       (SELECT count(*) FROM _upserted WHERE inserted),
       (SELECT count(*) FROM _upserted WHERE NOT inserted) + (SELECT count(*) FROM _soft_deleted)
         + (SELECT count(*) FROM _superseded),
       (SELECT count(*) FROM _fact_rejects),
       format('inserted=%s, updated (newer version)=%s, soft-deleted=%s, aliases deactivated=%s, unchanged (same/older version)=%s, rejected=%s',
              (SELECT count(*) FROM _upserted WHERE inserted),
              (SELECT count(*) FROM _upserted WHERE NOT inserted),
              (SELECT count(*) FROM _soft_deleted),
              (SELECT count(*) FROM _superseded),
              (SELECT count(*) FROM _mapped)
                - (SELECT count(*) FROM _upserted) - (SELECT count(*) FROM _soft_deleted),
              (SELECT count(*) FROM _fact_rejects));

INSERT INTO project_staging.etl_watermark (source_name, last_batch_id, max_event_time, max_source_updated_at, updated_at)
SELECT 'usgs_events', (SELECT batch_id FROM _fctx),
       (SELECT max(event_time) FROM project_dw.fact_seismic_event),
       (SELECT max(source_updated_at) FROM project_dw.fact_seismic_event),
       now()
ON CONFLICT (source_name) DO UPDATE
   SET last_batch_id = EXCLUDED.last_batch_id,
       max_event_time = EXCLUDED.max_event_time,
       max_source_updated_at = EXCLUDED.max_source_updated_at,
       updated_at = now();

UPDATE project_staging.etl_batch
   SET rows_rejected = (SELECT count(*) FROM project_staging.rejected_event
                        WHERE batch_id = (SELECT batch_id FROM _fctx)),
       status = 'LOADED',
       finished_at = now()
 WHERE batch_id = (SELECT batch_id FROM _fctx);
