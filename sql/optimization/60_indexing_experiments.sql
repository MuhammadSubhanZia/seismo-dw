/* ============================================================================
   60_indexing_experiments.sql  -  QUERY OPTIMIZATION (Phase 3, section 3)

   Supports deliverable: "Indexing Report (PDF)"         Aligned with Lab 09 / Lab 10

   Method for every experiment (Lab 10):
       1. reset   - drop the experiment index so the baseline is honest
       2. before  - EXPLAIN (ANALYZE, BUFFERS) of the workload query
       3. change  - CREATE INDEX (or CLUSTER) + ANALYZE
       4. after   - the identical EXPLAIN (ANALYZE, BUFFERS)
   Compare execution time, total query cost, scan type and shared buffers.

   The script runs as-is in pgAdmin / psql. etl/optimization.py executes the same
   file statement by statement, repeats every EXPLAIN 5 times (median time) and
   stores the measured plans in evidence/phase3/ - no number in the Indexing Report
   is typed by hand. Markers "-- @E<n> <phase>" tell the runner which experiment and
   phase the next EXPLAIN belongs to.

   fact_seismic_event: ~80.5k rows / ~31 MB. On a table this size PostgreSQL may
   rightly prefer a sequential scan; the report states what the planner actually did.
   Phase 2 already created one B-tree per foreign key (ix_fact_event_*); those stay.
   ============================================================================ */

SET search_path TO project_dw, public;

-- reset: remove every index this script creates, so a re-run starts from the same baseline
DROP INDEX IF EXISTS project_dw.ix_fact_event_time;
DROP INDEX IF EXISTS project_dw.ix_fact_event_location_date;
DROP INDEX IF EXISTS project_dw.ix_fact_event_major_time;
DROP INDEX IF EXISTS project_dw.ix_fact_event_date_covering;
DROP INDEX IF EXISTS project_dw.ix_fact_event_id_hash;
DROP TABLE IF EXISTS project_dw.fact_seismic_event_cluster_demo;
ANALYZE project_dw.fact_seismic_event;

/* ---------------------------------------------------------------------------
   E1  Date-range filter on a column with no index  ->  B-tree on event_time
   Workload: every event of March 2026 (drill-through list behind a month bar)
   --------------------------------------------------------------------------- */
DROP INDEX IF EXISTS project_dw.ix_fact_event_time;
-- @E1 before
EXPLAIN (ANALYZE, BUFFERS)
SELECT event_id, event_time, magnitude, depth_km
FROM project_dw.fact_seismic_event
WHERE event_time >= TIMESTAMPTZ '2026-03-01 00:00:00+00'
  AND event_time <  TIMESTAMPTZ '2026-04-01 00:00:00+00';
CREATE INDEX ix_fact_event_time ON project_dw.fact_seismic_event USING btree (event_time);
ANALYZE project_dw.fact_seismic_event;
-- @E1 after
EXPLAIN (ANALYZE, BUFFERS)
SELECT event_id, event_time, magnitude, depth_km
FROM project_dw.fact_seismic_event
WHERE event_time >= TIMESTAMPTZ '2026-03-01 00:00:00+00'
  AND event_time <  TIMESTAMPTZ '2026-04-01 00:00:00+00';

/* ---------------------------------------------------------------------------
   E2  Two predicates (location + date range) -> composite (location_key, date_key)
   Workload: Japan's events in 2025. Baseline can only combine the two single-column
   FK indexes (BitmapAnd) or use one of them.
   --------------------------------------------------------------------------- */
DROP INDEX IF EXISTS project_dw.ix_fact_event_location_date;
-- @E2 before
EXPLAIN (ANALYZE, BUFFERS)
SELECT event_id, date_key, magnitude
FROM project_dw.fact_seismic_event
WHERE location_key = (SELECT location_key FROM project_dw.dim_location WHERE location_code = 'JAPAN')
  AND date_key BETWEEN 20250101 AND 20251231;
CREATE INDEX ix_fact_event_location_date ON project_dw.fact_seismic_event (location_key, date_key);
ANALYZE project_dw.fact_seismic_event;
-- @E2 after
EXPLAIN (ANALYZE, BUFFERS)
SELECT event_id, date_key, magnitude
FROM project_dw.fact_seismic_event
WHERE location_key = (SELECT location_key FROM project_dw.dim_location WHERE location_code = 'JAPAN')
  AND date_key BETWEEN 20250101 AND 20251231;

/* ---------------------------------------------------------------------------
   E3  Highly selective business filter -> PARTIAL index
   Workload: the "major earthquakes" list (M6+, about 0.7% of rows) for 2025-2026.
   The partial index stores only qualifying rows, so it is tiny.
   --------------------------------------------------------------------------- */
DROP INDEX IF EXISTS project_dw.ix_fact_event_major_time;
-- @E3 before
EXPLAIN (ANALYZE, BUFFERS)
SELECT event_id, event_time, magnitude, location_key
FROM project_dw.fact_seismic_event
WHERE magnitude >= 6
  AND event_time >= TIMESTAMPTZ '2025-01-01 00:00:00+00'
ORDER BY event_time;
CREATE INDEX ix_fact_event_major_time ON project_dw.fact_seismic_event (event_time) WHERE magnitude >= 6;
ANALYZE project_dw.fact_seismic_event;
-- @E3 after
EXPLAIN (ANALYZE, BUFFERS)
SELECT event_id, event_time, magnitude, location_key
FROM project_dw.fact_seismic_event
WHERE magnitude >= 6
  AND event_time >= TIMESTAMPTZ '2025-01-01 00:00:00+00'
ORDER BY event_time;

/* ---------------------------------------------------------------------------
   E4  Aggregation that needs only a few columns -> COVERING index (INCLUDE)
   Workload: daily event count and energy for Q1 2025 (feeds the trend chart).
   After VACUUM the visibility map lets PostgreSQL answer from the index alone.
   --------------------------------------------------------------------------- */
DROP INDEX IF EXISTS project_dw.ix_fact_event_date_covering;
-- @E4 before
EXPLAIN (ANALYZE, BUFFERS)
SELECT date_key, count(*) AS events, sum(energy_joules) AS energy
FROM project_dw.fact_seismic_event
WHERE date_key BETWEEN 20250101 AND 20250331
GROUP BY date_key;
CREATE INDEX ix_fact_event_date_covering ON project_dw.fact_seismic_event (date_key) INCLUDE (energy_joules, magnitude);
VACUUM (ANALYZE) project_dw.fact_seismic_event;
-- @E4 after
EXPLAIN (ANALYZE, BUFFERS)
SELECT date_key, count(*) AS events, sum(energy_joules) AS energy
FROM project_dw.fact_seismic_event
WHERE date_key BETWEEN 20250101 AND 20250331
GROUP BY date_key;

/* ---------------------------------------------------------------------------
   E5  Equality lookup on the degenerate key -> HASH index vs the existing B-tree
   Workload: fetch one event by its USGS id (drill-through / support lookups).
   Hash supports equality only (no ranges, no ORDER BY).
   --------------------------------------------------------------------------- */
DROP INDEX IF EXISTS project_dw.ix_fact_event_id_hash;
-- @E5 before
EXPLAIN (ANALYZE, BUFFERS)
SELECT event_id, event_time, magnitude, place
FROM project_dw.fact_seismic_event
WHERE event_id = 'us6000qw60';
CREATE INDEX ix_fact_event_id_hash ON project_dw.fact_seismic_event USING hash (event_id);
ANALYZE project_dw.fact_seismic_event;
-- @E5 after
EXPLAIN (ANALYZE, BUFFERS)
SELECT event_id, event_time, magnitude, place
FROM project_dw.fact_seismic_event
WHERE event_id = 'us6000qw60';

/* ---------------------------------------------------------------------------
   E6  Physical order -> CLUSTER on the date index
   Loads append rows batch by batch, so one date range is spread over many heap pages.
   CLUSTER rewrites a table in date_key order so a range touches fewer pages. It is a
   one-off reorder (later inserts are not kept in order) and takes an ACCESS EXCLUSIVE
   lock, so it is demonstrated on a copy of the fact in its original load order.
   --------------------------------------------------------------------------- */
CREATE TABLE project_dw.fact_seismic_event_cluster_demo AS
SELECT * FROM project_dw.fact_seismic_event ORDER BY event_key;          -- load (insertion) order
CREATE INDEX ix_cluster_demo_date ON project_dw.fact_seismic_event_cluster_demo (date_key);
VACUUM (ANALYZE) project_dw.fact_seismic_event_cluster_demo;
-- @E6 before
EXPLAIN (ANALYZE, BUFFERS)
SELECT event_id, magnitude, depth_km, felt_reports
FROM project_dw.fact_seismic_event_cluster_demo
WHERE date_key BETWEEN 20250601 AND 20250630;
CLUSTER project_dw.fact_seismic_event_cluster_demo USING ix_cluster_demo_date;
VACUUM (ANALYZE) project_dw.fact_seismic_event_cluster_demo;
-- @E6 after
EXPLAIN (ANALYZE, BUFFERS)
SELECT event_id, magnitude, depth_km, felt_reports
FROM project_dw.fact_seismic_event_cluster_demo
WHERE date_key BETWEEN 20250601 AND 20250630;

/* ---------------------------------------------------------------------------
   E7  Reporting workload: the vw_monthly_sales view vs. reading a pre-aggregate
   An index cannot speed up a scan of every row; pre-aggregation can. The same monthly
   totals are read from the materialized view mv_daily_location_activity.
   --------------------------------------------------------------------------- */
-- @E7 before
EXPLAIN (ANALYZE, BUFFERS)
SELECT year_month, events, total_energy_tnt_tons
FROM project_reporting.vw_monthly_sales;
-- @E7 after
EXPLAIN (ANALYZE, BUFFERS)
SELECT d.year_month, sum(m.event_count) AS events, sum(m.total_energy_joules) / 4.184e9 AS total_energy_tnt_tons
FROM project_reporting.mv_daily_location_activity m
JOIN project_dw.dim_date d ON d.date_key = m.date_key
GROUP BY d.year_month;

/* ---------------------------------------------------------------------------
   Clean-up: keep the indexes that earned their place, drop the rest
   (decision justified in the Indexing Report; writes and storage are not free)
   --------------------------------------------------------------------------- */
DROP INDEX IF EXISTS project_dw.ix_fact_event_id_hash;        -- the UNIQUE B-tree already serves equality
DROP TABLE IF EXISTS project_dw.fact_seismic_event_cluster_demo;  -- demo copy only
SELECT indexname, pg_size_pretty(pg_relation_size(format('project_dw.%I', indexname)::regclass)) AS size
FROM pg_indexes WHERE schemaname = 'project_dw' AND tablename = 'fact_seismic_event'
ORDER BY indexname;
