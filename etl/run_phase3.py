"""
run_phase3.py - executes the Phase 3 SQL layer against the warehouse and exports evidence.

    python -m etl.run_phase3 analytics   run sql/analytics + sql/olap (+ reporting views) and export
                                         every "-- name:" query result to evidence/phase3/*.csv
    python -m etl.run_phase3 optimize    run the indexing / partitioning experiments
                                         (sql/optimization) and store measured plans
    python -m etl.run_phase3 all         both

Named queries are executed exactly as written in the SQL files, so the CSV evidence and
the PDF reports always match the submitted SQL.
"""
from __future__ import annotations

import argparse
import csv
import re
import time
from pathlib import Path

from .config import EVIDENCE_DIR, ROOT, SQL_DIR, connect

PHASE3_EVIDENCE = EVIDENCE_DIR / "phase3"
ANALYTIC_FILES = ["analytics/50_analytical_queries.sql", "olap/51_olap_queries.sql",
                  "analytics/53_business_insights.sql"]


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def split_named(path: Path) -> tuple[str, list[tuple[str, str]]]:
    """Return (preamble+DDL statements that are not named queries, [(name, sql), ...])."""
    text = path.read_text(encoding="utf-8")
    parts = re.split(r"^-- name:\s*(\w+)\s*$", text, flags=re.M)
    named = []
    for i in range(1, len(parts), 2):
        lines = parts[i + 1].splitlines(keepends=True)
        # a named query ends at the first code line that ends with ';' (comments may contain ';')
        end = next(j for j, ln in enumerate(lines)
                   if not ln.lstrip().startswith("--") and ln.rstrip().endswith(";"))
        stmt = "".join(lines[: end + 1]).rstrip().rstrip(";")
        named.append((parts[i], stmt.strip()))
        parts[i + 1] = "".join(lines[end + 1:])
    unnamed = parts[0] + "".join(parts[i + 1] for i in range(1, len(parts), 2))
    return unnamed, named


def export(cur, name: str, out_dir: Path) -> int:
    cols = [c.name for c in cur.description]
    rows = cur.fetchall()
    with open(out_dir / f"{name}.csv", "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(cols)
        w.writerows(rows)
    return len(rows)


def cmd_analytics() -> None:
    PHASE3_EVIDENCE.mkdir(parents=True, exist_ok=True)
    with connect() as conn:
        conn.execute((SQL_DIR / "reporting" / "52_reporting_views.sql").read_text(encoding="utf-8"))
        conn.commit()
        for rel in ANALYTIC_FILES:
            unnamed, named = split_named(SQL_DIR / rel)
            conn.execute(unnamed)           # SET search_path + MOLAP aggregate table DDL
            conn.commit()
            for name, sql in named:
                t0 = time.perf_counter()
                cur = conn.execute(sql)
                n = export(cur, name, PHASE3_EVIDENCE)
                log(f"  {rel:<36} {name:<32} {n:>5} rows  {1000 * (time.perf_counter() - t0):7.1f} ms")
        for view in ("vw_monthly_sales", "vw_customer_analysis", "vw_product_performance"):
            cur = conn.execute(f"SELECT * FROM project_reporting.{view}")
            log(f"  view project_reporting.{view:<28} {export(cur, view, PHASE3_EVIDENCE):>5} rows")


def cmd_optimize() -> None:
    from . import optimization
    optimization.run_all()


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["analytics", "optimize", "all"])
    a = ap.parse_args()
    if a.cmd in ("analytics", "all"):
        cmd_analytics()
    if a.cmd in ("optimize", "all"):
        cmd_optimize()


if __name__ == "__main__":
    main()
