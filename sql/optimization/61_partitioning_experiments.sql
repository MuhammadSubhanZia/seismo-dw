/* ============================================================================
   61_partitioning_experiments.sql  -  HORIZONTAL PARTITIONING (Lab 11, Phase 3 extension)

   Builds project_dw.fact_seismic_event_by_year, a RANGE-partitioned copy of the fact
   (partition key date_key, one partition per calendar year + DEFAULT), proves the
   copy reconciles, and shows PARTITION PRUNING with EXPLAIN.

   Why a copy and not the live fact? A primary key / unique constraint on a
   partitioned table must include the partition key, so UNIQUE (event_id) - the
   conflict key that makes the Phase 2 upsert idempotent - would become
   UNIQUE (event_id, date_key) and lose its meaning (an event whose date is revised
   could exist twice). The Indexing Report discusses this trade-off; at ~80k rows the
   warehouse does not need partitioning yet, and the experiment shows what changes.
   Markers "-- @P<n> <phase>" are read by etl/optimization.py.
   ============================================================================ */

SET search_path TO project_dw, public;

DROP TABLE IF EXISTS project_dw.fact_seismic_event_by_year;
CREATE TABLE project_dw.fact_seismic_event_by_year (
    LIKE project_dw.fact_seismic_event INCLUDING DEFAULTS
) PARTITION BY RANGE (date_key);
ALTER TABLE project_dw.fact_seismic_event_by_year ALTER COLUMN event_key DROP IDENTITY IF EXISTS;

CREATE TABLE project_dw.fact_seismic_event_y2024 PARTITION OF project_dw.fact_seismic_event_by_year
    FOR VALUES FROM (20240101) TO (20250101);
CREATE TABLE project_dw.fact_seismic_event_y2025 PARTITION OF project_dw.fact_seismic_event_by_year
    FOR VALUES FROM (20250101) TO (20260101);
CREATE TABLE project_dw.fact_seismic_event_y2026 PARTITION OF project_dw.fact_seismic_event_by_year
    FOR VALUES FROM (20260101) TO (20270101);
CREATE TABLE project_dw.fact_seismic_event_ydefault PARTITION OF project_dw.fact_seismic_event_by_year DEFAULT;

INSERT INTO project_dw.fact_seismic_event_by_year SELECT * FROM project_dw.fact_seismic_event;
ALTER TABLE project_dw.fact_seismic_event_by_year ADD PRIMARY KEY (event_key, date_key);
CREATE INDEX ix_fact_by_year_location ON project_dw.fact_seismic_event_by_year (location_key);
CREATE INDEX ix_fact_by_year_date ON project_dw.fact_seismic_event_by_year (date_key);   -- same as the live fact (fair comparison)
ANALYZE project_dw.fact_seismic_event_by_year;

-- reconciliation: counts and measures match the live fact; rows per physical partition
SELECT 'fact_seismic_event' AS source, count(*) AS rows, sum(magnitude) AS sum_magnitude
FROM project_dw.fact_seismic_event
UNION ALL
SELECT 'fact_seismic_event_by_year', count(*), sum(magnitude) FROM project_dw.fact_seismic_event_by_year;

SELECT tableoid::regclass AS partition, count(*) AS rows, min(date_key) AS first_date_key, max(date_key) AS last_date_key
FROM project_dw.fact_seismic_event_by_year
GROUP BY tableoid ORDER BY 1;

/* P1  March 2026 COUNT(*): unpartitioned fact vs partitioned copy (pruning to y2026) */
-- @P1 before
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM project_dw.fact_seismic_event
WHERE date_key BETWEEN 20260301 AND 20260331;
-- @P1 after
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM project_dw.fact_seismic_event_by_year
WHERE date_key BETWEEN 20260301 AND 20260331;

/* P2  Whole-year aggregate: pruning reads one partition instead of the full table */
-- @P2 before
EXPLAIN (ANALYZE, BUFFERS)
SELECT location_key, count(*), sum(energy_tnt_tons)
FROM project_dw.fact_seismic_event
WHERE date_key BETWEEN 20250101 AND 20251231
GROUP BY location_key;
-- @P2 after
EXPLAIN (ANALYZE, BUFFERS)
SELECT location_key, count(*), sum(energy_tnt_tons)
FROM project_dw.fact_seismic_event_by_year
WHERE date_key BETWEEN 20250101 AND 20251231
GROUP BY location_key;

/* P3  Query with no partition-key predicate: every partition is scanned (no pruning) */
-- @P3 before
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM project_dw.fact_seismic_event WHERE magnitude >= 7;
-- @P3 after
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM project_dw.fact_seismic_event_by_year WHERE magnitude >= 7;

/* Materialized view refresh and reconciliation (Lab 11 Part D) */
REFRESH MATERIALIZED VIEW CONCURRENTLY project_reporting.mv_daily_location_activity;
SELECT (SELECT sum(event_count) FROM project_reporting.mv_daily_location_activity) AS mv_events,
       (SELECT count(*) FROM project_dw.fact_seismic_event WHERE is_active)       AS fact_active_events;
