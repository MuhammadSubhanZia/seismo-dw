/* ============================================================================
   07_lineage_metadata.sql  -  METADATA & DATA LINEAGE (Phase 3 extension)

   Mirrors block 11 of the sample architecture:
       Source -> Raw (bronze) -> Staging (silver) -> DW -> Reporting (gold) -> Power BI

   meta_lineage_edge      static description of every hop: which object feeds which,
                          through which script, with what transformation
   meta_lineage_snapshot  row counts of every object, captured after each batch by
                          sql/quality/42_capture_lineage.sql (so lineage is auditable
                          over time: you can see where rows were filtered or merged)
   ============================================================================ */

SET search_path TO project_staging, public;

CREATE TABLE IF NOT EXISTS project_staging.meta_lineage_edge (
    edge_id         INT  PRIMARY KEY,
    hop_order       SMALLINT NOT NULL,
    layer_from      TEXT NOT NULL,
    object_from     TEXT NOT NULL,
    layer_to        TEXT NOT NULL,
    object_to       TEXT NOT NULL,
    script          TEXT NOT NULL,
    transformation  TEXT NOT NULL
);

INSERT INTO project_staging.meta_lineage_edge VALUES
 ( 1, 1, 'Source',    'USGS FDSN Event API',                     'Source',    'data/source/*.geojson.gz',                 'etl/extract_usgs.py',                         'API response frozen into a gzip GeoJSON file'),
 ( 2, 2, 'Source',    'data/source/*.geojson.gz',                'Raw',       'project_staging.raw_usgs_event',           'etl/load_raw.py',                             'COPY one row per feature, JSONB + md5, batch id'),
 ( 3, 2, 'Source',    'data/source/ref_*.csv',                   'Raw',       'project_staging.raw_* (reference)',        'etl/load_raw.py',                             'COPY CSV rows verbatim as TEXT'),
 ( 4, 3, 'Raw',       'project_staging.raw_* (reference)',       'Staging',   'project_staging.stg_* (reference)',        'sql/staging/11_clean_reference_to_staging.sql','trim, case, dedupe by code (last row wins)'),
 ( 5, 3, 'Raw',       'project_staging.raw_usgs_event',          'Staging',   'project_staging.stg_seismic_event',        'sql/staging/12_clean_events_to_staging.sql',  'parse, type, validate, dedupe, NULL rules, conform location'),
 ( 6, 3, 'Raw',       'project_staging.raw_usgs_event',          'Staging',   'project_staging.rejected_event',           'sql/staging/12_clean_events_to_staging.sql',  'quarantine with reason code'),
 ( 7, 4, 'Staging',   'project_staging.stg_*',                   'DW',        'project_dw.dim_* (7 dimensions)',          'sql/dimensions/20_..26_*.sql',                'surrogate keys, SCD1 / SCD2 (dim_network), inferred members'),
 ( 8, 4, 'Staging',   'project_staging.stg_seismic_event',       'DW',        'project_dw.fact_seismic_event',            'sql/facts/30_load_fact_seismic_event.sql',    'business key -> surrogate key, idempotent upsert'),
 ( 9, 5, 'DW',        'project_dw.fact_seismic_event',           'DW',        'project_dw.fact_location_monthly_snapshot','sql/facts/31_load_fact_location_monthly_snapshot.sql','dense month x location snapshot'),
 (10, 5, 'DW',        'project_dw.fact_seismic_event',           'DW',        'project_dw.fact_network_location_coverage','sql/facts/32_load_fact_network_location_coverage.sql','factless coverage fact'),
 (11, 6, 'DW',        'project_dw star schema',                  'Reporting', 'project_reporting views / mat. views',     'sql/reporting/04_*.sql, 52_reporting_views.sql','denormalise, aggregate, segment'),
 (12, 7, 'Reporting', 'project_reporting views + project_dw',    'BI',        'Power BI: powerbi/SeismoDW.pbix',          'powerbi/SeismoDW.pbip (import mode)',         'semantic model, DAX measures, 3 report pages')
ON CONFLICT (edge_id) DO UPDATE
   SET hop_order = EXCLUDED.hop_order, layer_from = EXCLUDED.layer_from, object_from = EXCLUDED.object_from,
       layer_to = EXCLUDED.layer_to, object_to = EXCLUDED.object_to, script = EXCLUDED.script,
       transformation = EXCLUDED.transformation;

CREATE TABLE IF NOT EXISTS project_staging.meta_lineage_snapshot (
    snapshot_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id          BIGINT,                      -- batch that triggered the capture
    layer           TEXT        NOT NULL,
    object_name     TEXT        NOT NULL,
    row_count       BIGINT      NOT NULL,
    captured_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_meta_lineage_snapshot_run ON project_staging.meta_lineage_snapshot (captured_at);
