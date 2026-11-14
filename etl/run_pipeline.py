"""
run_pipeline.py - ETL orchestrator for the Seismo data warehouse (PostgreSQL).

    Source files --(Python: extract + COPY)--> project_staging.raw_*
                 --(SQL: clean / dedupe / standardise / type)--> project_staging.stg_*
                 --(SQL: dimension loads, surrogate keys)--> project_dw.dim_*
                 --(SQL: business key -> surrogate key)--> project_dw.fact_seismic_event
                 --(SQL: data-quality checks)--> project_staging.dq_check_result
                 --> project_reporting (views / materialized view)

Transaction control (Lab 07): every batch runs in two transactions -
  1. raw load   (COPY)                      -> commit, batch status RAW_LOADED
  2. stage + dims + fact + quality checks   -> commit, batch status LOADED
If step 2 fails it is rolled back completely (no half-loaded warehouse), the batch is
marked FAILED and the raw rows stay available for reprocessing.

Usage
-----
  python -m etl.run_pipeline init [--reset]        create database, schemas and tables
  python -m etl.run_pipeline run                   load every file in the manifest (skips files already loaded)
  python -m etl.run_pipeline load FILE --type INCREMENTAL [--force]
  python -m etl.run_pipeline rerun-demo            re-load the 2026 batch unchanged and prove nothing changes
  python -m etl.run_pipeline quality               run the data-quality checks on the current warehouse
  python -m etl.run_pipeline evidence              export evidence CSVs into evidence/
  python -m etl.run_pipeline all                   init --reset + run + rerun-demo + evidence
"""
from __future__ import annotations

import argparse
import csv
import sys
import time
from pathlib import Path

import psycopg
from psycopg import sql

from . import load_raw
from .config import (DB_NAME, DDL_SCRIPTS, EVENT_BATCH_SCRIPTS, EVIDENCE_DIR, MANIFEST, QUALITY_SCRIPT,
                     REFERENCE_BATCH_SCRIPTS, SOURCE_DIR, SQL_DIR, connect, source_name_for)


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def run_sql_file(conn: psycopg.Connection, rel_path: str) -> None:
    text = (SQL_DIR / rel_path).read_text(encoding="utf-8")
    t0 = time.perf_counter()
    conn.execute(text)
    log(f"    ran {rel_path:<48} {time.perf_counter() - t0:6.2f}s")


# ---------------------------------------------------------------------------
# init
# ---------------------------------------------------------------------------
def cmd_init(reset: bool = False) -> None:
    with connect("postgres", autocommit=True) as admin:
        exists = admin.execute("SELECT 1 FROM pg_database WHERE datname = %s", (DB_NAME,)).fetchone()
        if not exists:
            admin.execute(sql.SQL("CREATE DATABASE {} ENCODING 'UTF8' TEMPLATE template0").format(sql.Identifier(DB_NAME)))
            log(f"created database {DB_NAME}")
    with connect() as conn:
        if reset:
            for schema in ("project_reporting", "project_dw", "project_staging"):
                conn.execute(sql.SQL("DROP SCHEMA IF EXISTS {} CASCADE").format(sql.Identifier(schema)))
            log("dropped existing schemas (--reset)")
        for script in DDL_SCRIPTS:
            run_sql_file(conn, script)
        conn.commit()
    log("schemas and tables ready")


# ---------------------------------------------------------------------------
# batch processing
# ---------------------------------------------------------------------------
def process_file(path: Path, load_type: str, force: bool = False) -> int | None:
    path = Path(path)
    if not path.is_absolute() and not path.exists():
        path = SOURCE_DIR / path
    source = source_name_for(path)
    sha = load_raw.file_sha256(path)

    with connect() as conn:
        conn.add_notice_handler(
            lambda d: None if "does not exist, skipping" in (d.message_primary or "")
            else log(f"    NOTICE: {d.message_primary}"))
        previous = load_raw.already_loaded(conn, sha)
        if previous and not force:
            bid = load_raw.register_batch(conn, source, path, load_type, sha, is_rerun=True, status="SKIPPED",
                                          message=f"identical file already loaded in batch {previous}; use --force to re-run")
            conn.commit()
            log(f"SKIPPED {path.name}: already loaded as batch {previous} (logged as batch {bid})")
            return None

        # -- transaction 1: raw load ------------------------------------------------
        batch_id = load_raw.register_batch(conn, source, path, load_type, sha, is_rerun=previous is not None)
        t0 = time.perf_counter()
        if source == "usgs_events":
            n = load_raw.load_geojson(conn, batch_id, path)
        else:
            n = load_raw.load_csv(conn, batch_id, path, source)
        conn.execute("UPDATE project_staging.etl_batch SET rows_read = %s, status = 'RAW_LOADED' WHERE batch_id = %s",
                     (n, batch_id))
        conn.commit()
        log(f"batch {batch_id} [{load_type}{' RERUN' if previous else ''}] {path.name}: "
            f"{n:,} raw rows loaded in {time.perf_counter() - t0:.1f}s")

        # -- transaction 2: transform + load + quality -------------------------------
        try:
            conn.execute("SELECT set_config('etl.batch_id', %s, true)", (str(batch_id),))
            scripts = EVENT_BATCH_SCRIPTS + [QUALITY_SCRIPT] if source == "usgs_events" else REFERENCE_BATCH_SCRIPTS
            for script in scripts:
                run_sql_file(conn, script)
            if source == "usgs_events":
                conn.execute("REFRESH MATERIALIZED VIEW project_reporting.mv_daily_location_activity")
            conn.commit()
        except Exception as exc:
            conn.rollback()
            conn.execute("UPDATE project_staging.etl_batch SET status = 'FAILED', finished_at = now(), "
                         "error_message = %s WHERE batch_id = %s", (str(exc)[:2000], batch_id))
            conn.commit()
            log(f"FAILED batch {batch_id}: {exc}")
            raise

        print_batch_summary(conn, batch_id)
        return batch_id


def print_batch_summary(conn: psycopg.Connection, batch_id: int) -> None:
    rows = conn.execute(
        """SELECT step_name, target_table, rows_processed, rows_inserted, rows_updated, rows_rejected, COALESCE(note, '')
           FROM project_staging.etl_step_log WHERE batch_id = %s ORDER BY step_id""", (batch_id,)).fetchall()
    for r in rows:
        log(f"    {r[0]:<16} {r[1]:<40} processed={r[2]:<7} ins={r[3]:<7} upd={r[4]:<6} rej={r[5]:<5} {r[6]}")


def cmd_run(force: bool = False) -> None:
    for file_name, load_type in MANIFEST:
        process_file(SOURCE_DIR / file_name, load_type, force=force)


def warehouse_totals(conn: psycopg.Connection) -> tuple:
    return conn.execute(
        """SELECT count(*), sum(magnitude), sum(energy_joules), sum(felt_reports), count(*) FILTER (WHERE is_active)
           FROM project_dw.fact_seismic_event""").fetchone()


def cmd_rerun_demo() -> None:
    """Lab 07 Task 6: re-run the second (2026) batch unchanged -> fact rows and totals must not change."""
    target = SOURCE_DIR / "usgs_events_2026_incremental.geojson.gz"
    with connect() as conn:
        before = warehouse_totals(conn)
    log(f"RERUN DEMO - before: rows={before[0]:,} sum_mag={before[1]} sum_energy={before[2]:.6e} felt={before[3]}")
    batch_id = process_file(target, "INCREMENTAL", force=True)
    with connect() as conn:
        after = warehouse_totals(conn)
        step = conn.execute("SELECT rows_inserted, rows_updated, note FROM project_staging.etl_step_log "
                            "WHERE batch_id = %s AND step_name = 'load_fact'", (batch_id,)).fetchone()
    log(f"RERUN DEMO - after:  rows={after[0]:,} sum_mag={after[1]} sum_energy={after[2]:.6e} felt={after[3]}")
    log(f"RERUN DEMO - fact step: inserted={step[0]} updated={step[1]} ({step[2]})")
    EVIDENCE_DIR.mkdir(exist_ok=True)
    with open(EVIDENCE_DIR / "09_idempotent_rerun_proof.csv", "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["measure", "before_rerun", "after_rerun", "unchanged"])
        for name, b, a in zip(["fact_rows", "sum_magnitude", "sum_energy_joules", "sum_felt_reports", "active_rows"],
                              before, after):
            w.writerow([name, b, a, b == a])
        w.writerow(["rerun_batch_id", batch_id, batch_id, ""])
        w.writerow(["fact_rows_inserted_by_rerun", "", step[0], step[0] == 0])
        w.writerow(["fact_rows_updated_by_rerun", "", step[1], step[1] == 0])
    if before != after or step[0] or step[1]:
        log("RERUN DEMO FAILED - warehouse changed")
        sys.exit(1)
    log("RERUN DEMO PASSED - identical row count and totals after re-running the batch")


def cmd_quality() -> None:
    with connect() as conn:
        run_sql_file(conn, QUALITY_SCRIPT)
        conn.commit()
        rows = conn.execute("SELECT check_code, status, check_name, expected_value, actual_value "
                            "FROM project_reporting.vw_dq_latest_run").fetchall()
    for r in rows:
        log(f"  {r[0]:<4} {r[1]:<4} {r[2]:<75} expected={r[3]} actual={r[4]}")
    fails = [r for r in rows if r[1] == "FAIL"]
    log(f"{len(rows)} checks, {len(fails)} FAIL")


# ---------------------------------------------------------------------------
# evidence export (query outputs used in the reports and for screenshots)
# ---------------------------------------------------------------------------
EVIDENCE_QUERIES = {
    "01_batch_summary.csv": "SELECT * FROM project_reporting.vw_etl_batch_summary ORDER BY batch_id",
    "02_etl_step_log.csv": "SELECT * FROM project_staging.etl_step_log ORDER BY step_id",
    "03_rejected_rows_by_reason.csv": """
        SELECT b.batch_id, b.source_file, r.stage, r.reason_code, count(*) AS rejected_rows
        FROM project_staging.rejected_event r JOIN project_staging.etl_batch b USING (batch_id)
        GROUP BY b.batch_id, b.source_file, r.stage, r.reason_code ORDER BY b.batch_id, r.stage, r.reason_code""",
    "04_data_quality_results.csv": "SELECT * FROM project_reporting.vw_dq_latest_run",
    "05_table_row_counts.csv": """
        SELECT 'project_staging' AS schema, 'raw_usgs_event' AS table_name, count(*) AS row_count FROM project_staging.raw_usgs_event
        UNION ALL SELECT 'project_staging', 'stg_seismic_event', count(*) FROM project_staging.stg_seismic_event
        UNION ALL SELECT 'project_staging', 'rejected_event', count(*) FROM project_staging.rejected_event
        UNION ALL SELECT 'project_dw', 'dim_date', count(*) FROM project_dw.dim_date
        UNION ALL SELECT 'project_dw', 'dim_location', count(*) FROM project_dw.dim_location
        UNION ALL SELECT 'project_dw', 'dim_network', count(*) FROM project_dw.dim_network
        UNION ALL SELECT 'project_dw', 'dim_magnitude_type', count(*) FROM project_dw.dim_magnitude_type
        UNION ALL SELECT 'project_dw', 'dim_event_type', count(*) FROM project_dw.dim_event_type
        UNION ALL SELECT 'project_dw', 'dim_magnitude_class', count(*) FROM project_dw.dim_magnitude_class
        UNION ALL SELECT 'project_dw', 'dim_depth_class', count(*) FROM project_dw.dim_depth_class
        UNION ALL SELECT 'project_dw', 'fact_seismic_event', count(*) FROM project_dw.fact_seismic_event
        UNION ALL SELECT 'project_reporting', 'mv_daily_location_activity', count(*) FROM project_reporting.mv_daily_location_activity""",
    "06_surrogate_key_mapping_trace.csv": """
        SELECT f.event_id,
               s.place AS source_place, s.location_code AS business_location_code, f.location_key,
               s.network_code AS business_network_code, f.network_key,
               s.magnitude_type AS business_magnitude_type, f.magnitude_type_key,
               s.event_type AS business_event_type, f.event_type_key,
               to_char(s.event_time AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') AS event_time_utc, f.date_key,
               s.magnitude, f.magnitude_class_key, s.depth_km, f.depth_class_key
        FROM project_dw.fact_seismic_event f
        JOIN project_staging.stg_seismic_event s ON s.event_id = f.event_id AND s.batch_id = f.updated_batch_id
        WHERE f.event_id IN (
            (SELECT event_id FROM project_dw.fact_seismic_event f2 JOIN project_dw.dim_location l USING (location_key)
             WHERE l.location_code = 'UNITED_STATES:CALIFORNIA' ORDER BY event_time LIMIT 1),
            (SELECT event_id FROM project_dw.fact_seismic_event f2 JOIN project_dw.dim_location l USING (location_key)
             WHERE l.location_code = 'JAPAN' ORDER BY magnitude DESC LIMIT 1),
            (SELECT event_id FROM project_dw.fact_seismic_event ORDER BY magnitude DESC LIMIT 1),
            (SELECT event_id FROM project_dw.fact_seismic_event f2 JOIN project_dw.dim_location l USING (location_key)
             WHERE l.location_code = 'PAKISTAN' ORDER BY magnitude DESC LIMIT 1))
        ORDER BY f.event_id""",
    "07_reconciliation.csv": """
        SELECT check_code, check_name, expected_value, actual_value, status, details
        FROM project_reporting.vw_dq_latest_run WHERE category = 'ACCURACY' ORDER BY check_code""",
    "08_text_standardisation_examples.csv": """
        SELECT CASE WHEN f.place LIKE '%,%' THEN btrim(regexp_replace(f.place, '^.*,', '')) ELSE f.place END AS raw_area_token,
               s.country, s.state_province, s.location_code, count(*) AS events
        FROM project_staging.v_raw_usgs_event_flat f
        JOIN project_staging.stg_seismic_event s ON s.raw_id = f.raw_id
        WHERE s.location_code IN ('UNITED_STATES:CALIFORNIA', 'MEXICO', 'JAPAN', 'FIJI', 'FIJI_ISLANDS',
                                  'UNITED_STATES:NEVADA', 'MYANMAR', 'MID_ATLANTIC_RIDGE', 'TIMOR_LESTE')
        GROUP BY 1, 2, 3, 4 ORDER BY s.location_code, events DESC""",
    "10_dimension_samples.csv": """
        (SELECT 'dim_location' AS dimension, location_key AS surrogate_key, location_code AS business_key, location_label AS label
           FROM project_dw.dim_location ORDER BY location_key LIMIT 8)
        UNION ALL (SELECT 'dim_network', network_key, network_code, network_name FROM project_dw.dim_network ORDER BY network_key LIMIT 8)
        UNION ALL (SELECT 'dim_magnitude_type', magnitude_type_key, magnitude_type_code, magnitude_type_name
                     FROM project_dw.dim_magnitude_type ORDER BY magnitude_type_key LIMIT 8)
        UNION ALL (SELECT 'dim_event_type', event_type_key, event_type_code, event_type_label FROM project_dw.dim_event_type ORDER BY event_type_key LIMIT 8)""",
}


def constraint_test(conn: psycopg.Connection) -> str:
    """Lab 06 Task 8.4: an INSERT that must fail because of FK / UNIQUE rules (rolled back, nothing kept)."""
    out = []
    tests = {
        "FOREIGN KEY (unknown location_key 999999)": """
            INSERT INTO project_dw.fact_seismic_event (event_id, date_key, location_key, network_key, magnitude_type_key,
                event_type_key, magnitude_class_key, depth_class_key, event_time, event_hour_utc, latitude, longitude,
                review_status, alert_level, tsunami_flag, is_significant, is_active, magnitude, depth_km, energy_joules,
                energy_tnt_tons, felt_reports, significance, source_updated_at, inserted_batch_id, updated_batch_id)
            VALUES ('TEST_ONLY', 20250101, 999999, -1, -1, -1, -1, -1, '2025-01-01', 0, 0, 0,
                    'reviewed', 'none', false, false, true, 4.0, 10, 1, 1, 0, 0, now(), 0, 0)""",
        "UNIQUE (duplicate business key in dim_network)": """
            INSERT INTO project_dw.dim_network (network_code, network_name, operator, region_served, network_type)
            VALUES ('us', 'duplicate', 'x', 'x', 'x')""",
        "UNIQUE (same event_id loaded twice)": """
            INSERT INTO project_dw.fact_seismic_event (event_id, date_key, location_key, network_key, magnitude_type_key,
                event_type_key, magnitude_class_key, depth_class_key, event_time, event_hour_utc, latitude, longitude,
                review_status, alert_level, tsunami_flag, is_significant, is_active, magnitude, depth_km, energy_joules,
                energy_tnt_tons, felt_reports, significance, source_updated_at, inserted_batch_id, updated_batch_id)
            SELECT event_id, date_key, location_key, network_key, magnitude_type_key, event_type_key, magnitude_class_key,
                   depth_class_key, event_time, event_hour_utc, latitude, longitude, review_status, alert_level,
                   tsunami_flag, is_significant, is_active, magnitude, depth_km, energy_joules, energy_tnt_tons,
                   felt_reports, significance, source_updated_at, inserted_batch_id, updated_batch_id
            FROM project_dw.fact_seismic_event LIMIT 1""",
    }
    for name, stmt in tests.items():
        try:
            with conn.transaction():
                conn.execute(stmt)
                raise RuntimeError("UNEXPECTED: insert succeeded")
        except psycopg.errors.IntegrityError as exc:
            out.append(f"-- {name}\n{' '.join(stmt.split())}\n=> REJECTED by PostgreSQL: "
                       f"{exc.diag.sqlstate} {exc.diag.message_primary}\n   {exc.diag.message_detail or ''}\n")
    return "\n".join(out)


def cmd_evidence() -> None:
    EVIDENCE_DIR.mkdir(exist_ok=True)
    with connect() as conn:
        for file_name, query in EVIDENCE_QUERIES.items():
            cur = conn.execute(query)
            cols = [c.name for c in cur.description]
            rows = cur.fetchall()
            with open(EVIDENCE_DIR / file_name, "w", newline="", encoding="utf-8") as fh:
                w = csv.writer(fh)
                w.writerow(cols)
                w.writerows(rows)
            log(f"  wrote evidence/{file_name} ({len(rows)} rows)")
        text = constraint_test(conn)
        (EVIDENCE_DIR / "11_constraint_test.txt").write_text(text, encoding="utf-8")
        log("  wrote evidence/11_constraint_test.txt")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p_init = sub.add_parser("init")
    p_init.add_argument("--reset", action="store_true", help="drop and recreate the three schemas")
    p_run = sub.add_parser("run")
    p_run.add_argument("--force", action="store_true")
    p_load = sub.add_parser("load")
    p_load.add_argument("file", type=Path)
    p_load.add_argument("--type", default="INCREMENTAL", choices=["FULL_LOAD", "INCREMENTAL", "REFERENCE"])
    p_load.add_argument("--force", action="store_true")
    sub.add_parser("rerun-demo")
    sub.add_parser("quality")
    sub.add_parser("evidence")
    sub.add_parser("all")
    a = ap.parse_args()

    t0 = time.perf_counter()
    if a.cmd == "init":
        cmd_init(a.reset)
    elif a.cmd == "run":
        cmd_run(a.force)
    elif a.cmd == "load":
        process_file(a.file, a.type, a.force)
    elif a.cmd == "rerun-demo":
        cmd_rerun_demo()
    elif a.cmd == "quality":
        cmd_quality()
    elif a.cmd == "evidence":
        cmd_evidence()
    elif a.cmd == "all":
        cmd_init(reset=True)
        cmd_run()
        cmd_rerun_demo()
        cmd_quality()
        cmd_evidence()
    log(f"done in {time.perf_counter() - t0:.1f}s")


if __name__ == "__main__":
    main()
