"""
optimization.py - runs sql/optimization/60_* and 61_* exactly as written and measures them.

Every statement is executed in file order (autocommit, because VACUUM and CLUSTER cannot
run inside a transaction). For each EXPLAIN (ANALYZE, BUFFERS) statement that follows a
"-- @E1 before" style marker, the runner:
  * runs the same statement with FORMAT JSON 5 times (first run warms the cache),
  * keeps the median execution time, the planner's total cost, the top scan node types,
    shared buffers hit/read and rows returned,
  * saves the full text plan of the median run.

Output: evidence/phase3/optimization_results.json and optimization_results.csv and
evidence/phase3/plans/<experiment>_<phase>.txt - the Indexing Report is built from these.
"""
from __future__ import annotations

import csv
import json
import re
import statistics
import time
from pathlib import Path

from .config import EVIDENCE_DIR, SQL_DIR, connect

OUT = EVIDENCE_DIR / "phase3"
FILES = ["optimization/60_indexing_experiments.sql", "optimization/61_partitioning_experiments.sql"]
RUNS = 5
MARKER = re.compile(r"^--\s*@([EP]\d+)\s+(before|after)\s*$")


def statements(path: Path):
    """Yield (marker_or_None, sql) for every statement; ';' only terminates outside comments."""
    marker, buf = None, []
    for line in path.read_text(encoding="utf-8").splitlines():
        m = MARKER.match(line.strip())
        if m:
            marker = (m.group(1), m.group(2))
            continue
        if not buf and (line.strip().startswith("--") or not line.strip()):
            continue
        buf.append(line)
        code = line.split("--", 1)[0].rstrip()
        if code.endswith(";"):
            sql = "\n".join(buf).strip().rstrip(";")
            buf = []
            if sql.startswith("/*"):
                sql = re.sub(r"/\*.*?\*/", "", sql, flags=re.S).strip()
            if sql:
                yield marker, sql
                if sql.upper().startswith("EXPLAIN"):
                    marker = None


def walk(node, acc):
    acc.append(node)
    for child in node.get("Plans", []):
        walk(child, acc)
    return acc


def measure(conn, sql: str) -> dict:
    json_sql = re.sub(r"EXPLAIN\s*\(ANALYZE,\s*BUFFERS\)", "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)", sql, count=1)
    runs = []
    for _ in range(RUNS):
        plan = conn.execute(json_sql).fetchone()[0][0]
        runs.append(plan)
    runs = runs[1:]                                   # drop the cold-cache run
    times = [r["Execution Time"] for r in runs]
    median_run = sorted(runs, key=lambda r: r["Execution Time"])[len(runs) // 2]
    top = median_run["Plan"]
    nodes = walk(top, [])
    scans = [n["Node Type"] + (f" on {n.get('Relation Name')}" if n.get("Relation Name") else "")
             + (f" using {n['Index Name']}" if n.get("Index Name") else "")
             for n in nodes if "Scan" in n["Node Type"]]
    text_plan = "\n".join(r[0] for r in conn.execute(sql.replace("(ANALYZE, BUFFERS)", "(ANALYZE, BUFFERS, COSTS)")).fetchall())
    return {
        "execution_ms_median": round(statistics.median(times), 3),
        "execution_ms_runs": [round(t, 3) for t in times],
        "planning_ms": round(median_run["Planning Time"], 3),
        "total_cost": top["Total Cost"],
        "rows": top.get("Actual Rows"),
        "top_node": top["Node Type"],
        "scan_nodes": scans,
        "shared_hit": sum(n.get("Shared Hit Blocks", 0) for n in [top]),
        "shared_read": sum(n.get("Shared Read Blocks", 0) for n in [top]),
        "partitions_scanned": sorted({n.get("Relation Name") for n in nodes if n.get("Relation Name", "").startswith("fact_seismic_event_y")}),
        "plan_text": text_plan,
    }


def run_all() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "plans").mkdir(exist_ok=True)
    results = []
    with connect(autocommit=True) as conn:
        for rel in FILES:
            for marker, sql in statements(SQL_DIR / rel):
                head = " ".join(sql.split())[:90]
                if marker and sql.upper().startswith("EXPLAIN"):
                    r = measure(conn, sql)
                    exp, phase = marker
                    r.update({"experiment": exp, "phase": phase, "file": rel, "query": sql})
                    (OUT / "plans" / f"{exp}_{phase}.txt").write_text(sql + "\n\n" + r.pop("plan_text"), encoding="utf-8")
                    results.append(r)
                    print(f"[{time.strftime('%H:%M:%S')}] {exp} {phase:<6} {r['execution_ms_median']:>9.3f} ms  "
                          f"cost {r['total_cost']:>10.2f}  {', '.join(r['scan_nodes'][:2])}", flush=True)
                else:
                    cur = conn.execute(sql)
                    if cur.description and rel.endswith("61_partitioning_experiments.sql"):
                        rows = cur.fetchall()
                        name = "partition_reconciliation" if "sum_magnitude" in [c.name for c in cur.description] else \
                               "partition_rows" if "partition" in [c.name for c in cur.description] else "mv_reconciliation"
                        with open(OUT / f"{name}.csv", "w", newline="", encoding="utf-8") as fh:
                            w = csv.writer(fh)
                            w.writerow([c.name for c in cur.description])
                            w.writerows(rows)
                    elif cur.description and "pg_indexes" in sql:
                        rows = cur.fetchall()
                        with open(OUT / "final_fact_indexes.csv", "w", newline="", encoding="utf-8") as fh:
                            w = csv.writer(fh)
                            w.writerow([c.name for c in cur.description])
                            w.writerows(rows)
                    print(f"[{time.strftime('%H:%M:%S')}]    ran: {head}", flush=True)
    (OUT / "optimization_results.json").write_text(json.dumps(results, indent=2, default=str), encoding="utf-8")
    with open(OUT / "optimization_results.csv", "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["experiment", "phase", "execution_ms_median", "planning_ms", "total_cost", "rows",
                    "top_node", "scan_nodes", "shared_hit", "shared_read", "partitions_scanned"])
        for r in results:
            w.writerow([r["experiment"], r["phase"], r["execution_ms_median"], r["planning_ms"], r["total_cost"],
                        r["rows"], r["top_node"], " | ".join(r["scan_nodes"]), r["shared_hit"], r["shared_read"],
                        " ".join(r["partitions_scanned"])])
    print(f"wrote {len(results)} measured plans to evidence/phase3/")
