/* ============================================================================
   02_staging_schema.sql  -  STAGING SCHEMA (project_staging)

   Deliverable: "Staging Schema SQL"

   The staging schema has four groups of objects:

   A. ETL control      etl_batch, etl_step_log, etl_watermark
   B. Raw landing      raw_usgs_event, raw_seismic_network, raw_magnitude_type,
                       raw_us_state, raw_country_alias
                       -> rows exactly as they arrived (Lab 06 checkpoint:
                          "do not hide source defects"). No surrogate keys, no cleaning,
                          permissive TEXT/JSONB types. Never updated or deleted.
   C. Clean staging    stg_seismic_event, stg_seismic_network, stg_magnitude_type,
                       stg_us_state, stg_country_alias
                       -> de-duplicated, NULL-handled, standardised, typed.
   D. Data quality     rejected_event (quarantine), dq_check_result

   Mapping to the Seismo (Databricks) project:
       bronze_seismic_events            -> raw_usgs_event
       silver_seismic_events            -> stg_seismic_event
       silver_seismic_events_quarantine -> rejected_event
       pipeline_execution_log           -> etl_batch + etl_step_log

   Idempotent: safe to run more than once.
   ============================================================================ */

SET search_path TO project_staging, public;

/* ---------------------------------------------------------------------------
   Helper functions used by the cleaning scripts
   --------------------------------------------------------------------------- */

-- TRIM + collapse internal whitespace; empty string -> NULL
CREATE OR REPLACE FUNCTION project_staging.fn_clean_text(p TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
    SELECT NULLIF(regexp_replace(btrim(p), '\s+', ' ', 'g'), '')
$$;

-- Safe numeric cast: returns NULL instead of raising on bad input
CREATE OR REPLACE FUNCTION project_staging.fn_try_numeric(p TEXT)
RETURNS NUMERIC LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    RETURN NULLIF(btrim(p), '')::NUMERIC;
EXCEPTION WHEN others THEN
    RETURN NULL;
END $$;

-- USGS epoch milliseconds (text) -> TIMESTAMPTZ (UTC)
CREATE OR REPLACE FUNCTION project_staging.fn_epoch_ms_to_ts(p TEXT)
RETURNS TIMESTAMPTZ LANGUAGE sql IMMUTABLE AS $$
    SELECT to_timestamp(project_staging.fn_try_numeric(p) / 1000.0)
$$;

/* ---------------------------------------------------------------------------
   A. ETL CONTROL
   --------------------------------------------------------------------------- */

CREATE TABLE IF NOT EXISTS project_staging.etl_batch (
    batch_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_name     TEXT        NOT NULL,          -- usgs_events / ref_seismic_networks / ...
    source_file     TEXT        NOT NULL,
    file_sha256     CHAR(64)    NOT NULL,          -- same file => same hash => rerun detection
    load_type       TEXT        NOT NULL
                    CHECK (load_type IN ('FULL_LOAD', 'INCREMENTAL', 'REFERENCE')),
    is_rerun        BOOLEAN     NOT NULL DEFAULT FALSE,
    status          TEXT        NOT NULL DEFAULT 'RUNNING'
                    CHECK (status IN ('RUNNING', 'RAW_LOADED', 'LOADED', 'FAILED', 'SKIPPED')),
    rows_read       INT,
    rows_duplicate  INT         NOT NULL DEFAULT 0,
    rows_rejected   INT         NOT NULL DEFAULT 0,
    rows_staged     INT,
    started_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at     TIMESTAMPTZ,
    error_message   TEXT
);
COMMENT ON TABLE project_staging.etl_batch IS 'One row per source file load (batch). Lab 07 Task 1 audit table.';

CREATE TABLE IF NOT EXISTS project_staging.etl_step_log (
    step_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_id        BIGINT      REFERENCES project_staging.etl_batch (batch_id),
    step_name       TEXT        NOT NULL,
    target_table    TEXT        NOT NULL,
    rows_processed  INT         NOT NULL DEFAULT 0,
    rows_inserted   INT         NOT NULL DEFAULT 0,
    rows_updated    INT         NOT NULL DEFAULT 0,
    rows_rejected   INT         NOT NULL DEFAULT 0,
    note            TEXT,
    logged_at       TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);
COMMENT ON TABLE project_staging.etl_step_log IS 'Row counts written by every ETL step (staging, each dimension, fact).';

CREATE TABLE IF NOT EXISTS project_staging.etl_watermark (
    source_name             TEXT PRIMARY KEY,
    last_batch_id           BIGINT REFERENCES project_staging.etl_batch (batch_id),
    max_event_time          TIMESTAMPTZ,       -- newest event origin time loaded
    max_source_updated_at   TIMESTAMPTZ,       -- newest USGS "updated" timestamp loaded
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE project_staging.etl_watermark IS 'Incremental-load watermark (Lab 07 Task 6).';

/* ---------------------------------------------------------------------------
   B. RAW LANDING (as delivered, immutable)
   --------------------------------------------------------------------------- */

-- One row per GeoJSON feature exactly as delivered by the USGS API.
CREATE TABLE IF NOT EXISTS project_staging.raw_usgs_event (
    raw_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_id        BIGINT      NOT NULL REFERENCES project_staging.etl_batch (batch_id),
    source_row_num  INT         NOT NULL,          -- position of the feature in the source file
    feature         JSONB       NOT NULL,          -- full GeoJSON feature, untouched
    record_hash     CHAR(32)    NOT NULL,          -- md5(feature) for change detection
    loaded_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_raw_usgs_event_row UNIQUE (batch_id, source_row_num)
);
CREATE INDEX IF NOT EXISTS ix_raw_usgs_event_batch ON project_staging.raw_usgs_event (batch_id);

-- Flat, all-TEXT projection of the raw JSON - used for profiling (no cleaning applied).
CREATE OR REPLACE VIEW project_staging.v_raw_usgs_event_flat AS
SELECT r.raw_id,
       r.batch_id,
       r.source_row_num,
       r.feature ->> 'id'                                  AS event_id,
       r.feature -> 'properties' ->> 'mag'                 AS mag,
       r.feature -> 'properties' ->> 'magType'             AS mag_type,
       r.feature -> 'properties' ->> 'place'               AS place,
       r.feature -> 'properties' ->> 'time'                AS time_ms,
       r.feature -> 'properties' ->> 'updated'             AS updated_ms,
       r.feature -> 'properties' ->> 'status'              AS status,
       r.feature -> 'properties' ->> 'type'                AS event_type,
       r.feature -> 'properties' ->> 'net'                 AS net,
       r.feature -> 'properties' ->> 'alert'               AS alert,
       r.feature -> 'properties' ->> 'tsunami'             AS tsunami,
       r.feature -> 'properties' ->> 'felt'                AS felt,
       r.feature -> 'properties' ->> 'cdi'                 AS cdi,
       r.feature -> 'properties' ->> 'mmi'                 AS mmi,
       r.feature -> 'properties' ->> 'sig'                 AS sig,
       r.feature -> 'properties' ->> 'nst'                 AS nst,
       r.feature -> 'properties' ->> 'gap'                 AS gap,
       r.feature -> 'properties' ->> 'rms'                 AS rms,
       r.feature -> 'properties' ->> 'dmin'                AS dmin,
       r.feature -> 'geometry' -> 'coordinates' ->> 0      AS longitude,
       r.feature -> 'geometry' -> 'coordinates' ->> 1      AS latitude,
       r.feature -> 'geometry' -> 'coordinates' ->> 2      AS depth,
       r.record_hash
FROM project_staging.raw_usgs_event r;

-- Reference CSV extracts: columns match the CSV headers, everything TEXT.
CREATE TABLE IF NOT EXISTS project_staging.raw_seismic_network (
    raw_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_id        BIGINT NOT NULL REFERENCES project_staging.etl_batch (batch_id),
    source_row_num  INT    NOT NULL,
    network_code    TEXT,
    network_name    TEXT,
    operator        TEXT,
    region_served   TEXT,
    network_type    TEXT,
    loaded_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS project_staging.raw_magnitude_type (
    raw_id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_id             BIGINT NOT NULL REFERENCES project_staging.etl_batch (batch_id),
    source_row_num       INT    NOT NULL,
    magnitude_type_code  TEXT,
    magnitude_type_name  TEXT,
    scale_family         TEXT,
    description          TEXT,
    loaded_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS project_staging.raw_us_state (
    raw_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_id        BIGINT NOT NULL REFERENCES project_staging.etl_batch (batch_id),
    source_row_num  INT    NOT NULL,
    state_code      TEXT,
    state_name      TEXT,
    match_by_name   TEXT,
    loaded_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS project_staging.raw_country_alias (
    raw_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_id        BIGINT NOT NULL REFERENCES project_staging.etl_batch (batch_id),
    source_row_num  INT    NOT NULL,
    alias           TEXT,
    country         TEXT,
    note            TEXT,
    loaded_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

/* ---------------------------------------------------------------------------
   C. CLEAN STAGING (de-duplicated, standardised, typed)
   --------------------------------------------------------------------------- */

-- One cleaned row per (batch, event). History across batches is kept so the
-- warehouse load can be reconciled back to every batch.
CREATE TABLE IF NOT EXISTS project_staging.stg_seismic_event (
    batch_id           BIGINT        NOT NULL REFERENCES project_staging.etl_batch (batch_id),
    event_id           TEXT          NOT NULL,         -- USGS business key
    associated_ids     TEXT[]        NOT NULL,         -- every id USGS links to this event (incl. merged ids)
    raw_id             BIGINT        NOT NULL REFERENCES project_staging.raw_usgs_event (raw_id),
    event_time         TIMESTAMPTZ   NOT NULL,         -- converted from epoch ms (UTC)
    source_updated_at  TIMESTAMPTZ   NOT NULL,         -- USGS "updated" (version timestamp)
    magnitude          NUMERIC(4,2)  NOT NULL,
    magnitude_type     TEXT,                           -- lower-case code, NULL = not reported
    depth_km           NUMERIC(8,3)  NOT NULL,
    latitude           NUMERIC(9,6)  NOT NULL,
    longitude          NUMERIC(9,6)  NOT NULL,
    place              TEXT,                           -- trimmed original description
    nearest_place      TEXT,                           -- place without "NN km DIR of"
    country            TEXT          NOT NULL,         -- conformed country / territory / ocean area
    state_province     TEXT          NOT NULL,         -- US state or 'N/A'
    location_type      TEXT          NOT NULL,
    location_code      TEXT,                           -- business key for dim_location (NULL = unknown)
    network_code       TEXT,
    event_type         TEXT,
    review_status      TEXT          NOT NULL,         -- automatic / reviewed / deleted / unknown
    alert_level        TEXT          NOT NULL,         -- none / green / yellow / orange / red
    tsunami_flag       BOOLEAN       NOT NULL,
    felt_reports       INT           NOT NULL,         -- NULL in source => 0 reports
    cdi                NUMERIC(4,2),                   -- NULL kept: not measured
    mmi                NUMERIC(5,3),
    significance       INT           NOT NULL,
    station_count      INT,
    azimuthal_gap      NUMERIC(6,2),
    rms_residual       NUMERIC(8,4),
    min_distance_deg   NUMERIC(9,4),
    is_active          BOOLEAN       NOT NULL,         -- FALSE when USGS status = deleted
    record_hash        CHAR(32)      NOT NULL,
    staged_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    CONSTRAINT pk_stg_seismic_event PRIMARY KEY (batch_id, event_id)
);
CREATE INDEX IF NOT EXISTS ix_stg_seismic_event_event ON project_staging.stg_seismic_event (event_id);
CREATE INDEX IF NOT EXISTS ix_stg_seismic_event_assoc ON project_staging.stg_seismic_event USING gin (associated_ids);

CREATE TABLE IF NOT EXISTS project_staging.stg_seismic_network (
    network_code    TEXT PRIMARY KEY,
    network_name    TEXT NOT NULL,
    operator        TEXT,
    region_served   TEXT,
    network_type    TEXT,
    source_batch_id BIGINT REFERENCES project_staging.etl_batch (batch_id),
    staged_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS project_staging.stg_magnitude_type (
    magnitude_type_code TEXT PRIMARY KEY,
    magnitude_type_name TEXT NOT NULL,
    scale_family        TEXT NOT NULL,
    description         TEXT,
    source_batch_id     BIGINT REFERENCES project_staging.etl_batch (batch_id),
    staged_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS project_staging.stg_us_state (
    state_code      CHAR(2) PRIMARY KEY,
    state_name      TEXT    NOT NULL UNIQUE,
    match_by_name   BOOLEAN NOT NULL,
    source_batch_id BIGINT REFERENCES project_staging.etl_batch (batch_id)
);

CREATE TABLE IF NOT EXISTS project_staging.stg_country_alias (
    alias_upper     TEXT PRIMARY KEY,                 -- matching is case-insensitive
    country         TEXT NOT NULL,
    source_batch_id BIGINT REFERENCES project_staging.etl_batch (batch_id)
);

/* ---------------------------------------------------------------------------
   D. DATA QUALITY
   --------------------------------------------------------------------------- */

-- Quarantine: every row that did not reach the warehouse, with the reason.
CREATE TABLE IF NOT EXISTS project_staging.rejected_event (
    reject_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_id       BIGINT      NOT NULL REFERENCES project_staging.etl_batch (batch_id),
    raw_id         BIGINT      REFERENCES project_staging.raw_usgs_event (raw_id),
    event_id       TEXT,
    stage          TEXT        NOT NULL CHECK (stage IN ('STAGING', 'FACT_LOAD')),
    reason_code    TEXT        NOT NULL,
    reason_detail  TEXT,
    rejected_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_rejected_event UNIQUE (batch_id, raw_id, stage)
);

-- Results of every data-quality check run (completeness / accuracy / integrity ...)
CREATE TABLE IF NOT EXISTS project_staging.dq_check_result (
    result_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id         BIGINT      NOT NULL,              -- batch that triggered the run
    check_code     TEXT        NOT NULL,
    category       TEXT        NOT NULL
                   CHECK (category IN ('COMPLETENESS', 'ACCURACY', 'INTEGRITY', 'UNIQUENESS', 'VALIDITY', 'CONSISTENCY')),
    check_name     TEXT        NOT NULL,
    target_object  TEXT        NOT NULL,
    expected_value NUMERIC,
    actual_value   NUMERIC,
    status         TEXT        NOT NULL CHECK (status IN ('PASS', 'FAIL', 'INFO')),
    details        TEXT,
    run_started_at TIMESTAMPTZ NOT NULL DEFAULT now(),           -- transaction time: groups one run
    checked_at     TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX IF NOT EXISTS ix_dq_check_result_run ON project_staging.dq_check_result (run_id);
