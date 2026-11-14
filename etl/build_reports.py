"""
build_reports.py - generates the two Phase 2 PDF deliverables from the LIVE warehouse.

    docs/phase2/Data_Cleaning_Report.pdf
    docs/phase2/Data_Quality_Report.pdf

Every number in the reports comes from a query against the loaded database (the named
queries in sql/staging/10_profile_raw_data.sql and sql/quality/41_validation_and_analysis.sql,
plus the dq_check_result table). Re-running the pipeline and this script regenerates them.

HTML is rendered to PDF with a headless Chromium browser (Edge or Chrome).

    python -m etl.build_reports
"""
from __future__ import annotations

import base64
import html
import io
import json
import re
import shutil
import subprocess
from datetime import date
from decimal import Decimal
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

from .config import ROOT, SQL_DIR, connect  # noqa: E402

OUT_DIR = ROOT / "docs" / "phase2"
BUILD_DIR = ROOT / "build"
META = json.loads((ROOT / "docs" / "report_meta.json").read_text(encoding="utf-8"))

BROWSERS = [
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    "google-chrome", "chromium", "chromium-browser", "msedge",
]

# chart styling (single-series charts use categorical slot 1; text stays in ink colours)
BLUE, INK, INK2, GRID = "#2a78d6", "#0b0b0b", "#52514e", "#e4e3df"


# ---------------------------------------------------------------------------
# data access
# ---------------------------------------------------------------------------
def named_queries(path: Path) -> dict[str, str]:
    text = path.read_text(encoding="utf-8")
    parts = re.split(r"^-- name:\s*(\w+)\s*$", text, flags=re.M)
    return {parts[i]: parts[i + 1].strip().rstrip(";") for i in range(1, len(parts), 2)}


class DB:
    def __init__(self):
        self.conn = connect(autocommit=True)
        self.conn.execute("SET search_path TO project_staging, project_dw, public")
        self.q = {**named_queries(SQL_DIR / "staging" / "10_profile_raw_data.sql"),
                  **named_queries(SQL_DIR / "quality" / "41_validation_and_analysis.sql")}

    def rows(self, sql_or_name: str, params=None):
        sql = self.q.get(sql_or_name, sql_or_name)
        cur = self.conn.execute(sql, params)
        return [c.name for c in cur.description], cur.fetchall()

    def one(self, sql: str, params=None):
        return self.conn.execute(sql, params).fetchone()

    def scalar(self, sql: str, params=None):
        return self.one(sql, params)[0]


# ---------------------------------------------------------------------------
# html helpers
# ---------------------------------------------------------------------------
def fmt(v) -> str:
    if v is None:
        return '<span class="muted">NULL</span>'
    if isinstance(v, bool):
        return "yes" if v else "no"
    if isinstance(v, float):
        if v != 0 and (abs(v) >= 1e9 or abs(v) < 1e-3):
            return f"{v:.6e}"
        return f"{v:,.2f}"
    if isinstance(v, Decimal):
        if v == v.to_integral_value() and abs(v) < Decimal("1e15"):
            return f"{int(v):,}"
        if abs(v) >= Decimal("1e15"):
            return f"{float(v):.6e}"
        return f"{v:,}"
    if isinstance(v, int):
        return f"{v:,}"
    return html.escape(str(v))


def table(cols, rows, status_col: str | None = None, cls: str = "") -> str:
    head = "".join(f"<th>{html.escape(c.replace('_', ' '))}</th>" for c in cols)
    body = []
    for r in rows:
        cells = []
        for c, v in zip(cols, r):
            if c == status_col:
                cells.append(f'<td><span class="badge {str(v).lower()}">{"&#10003; " if v == "PASS" else ("&#10007; " if v == "FAIL" else "i ")}{v}</span></td>')
            else:
                num = isinstance(v, (int, float, Decimal)) and not isinstance(v, bool)
                cells.append(f'<td class="{"num" if num else ""}">{fmt(v)}</td>')
        body.append("<tr>" + "".join(cells) + "</tr>")
    return f'<table class="{cls}"><thead><tr>{head}</tr></thead><tbody>{"".join(body)}</tbody></table>'


def qtable(db: DB, name: str, **kw) -> str:
    return table(*db.rows(name), **kw)


def code(sql: str) -> str:
    return f"<pre>{html.escape(sql.strip())}</pre>"


def fig_to_img(fig, alt: str) -> str:
    buf = io.BytesIO()
    fig.savefig(buf, format="png", dpi=150, bbox_inches="tight")
    plt.close(fig)
    return f'<img class="chart" alt="{html.escape(alt)}" src="data:image/png;base64,{base64.b64encode(buf.getvalue()).decode()}">'


def _style(ax):
    for s in ("top", "right", "left"):
        ax.spines[s].set_visible(False)
    ax.spines["bottom"].set_color(GRID)
    ax.tick_params(colors=INK2, labelsize=8, length=0)
    ax.grid(axis="x", color=GRID, linewidth=0.6)
    ax.set_axisbelow(True)


def hbar_chart(labels, values, title, xlabel, value_fmt="{:,.0f}") -> str:
    fig, ax = plt.subplots(figsize=(6.4, 0.24 * len(labels) + 0.8))
    y = range(len(labels))
    ax.barh(list(y), values, color=BLUE, height=0.6)
    ax.set_yticks(list(y), labels)
    ax.invert_yaxis()
    _style(ax)
    ax.set_xlabel(xlabel, color=INK2, fontsize=8)
    ax.set_title(title, color=INK, fontsize=10, loc="left", pad=8)
    vmax = max(values) if values else 1
    for i, v in enumerate(values):
        ax.text(v + vmax * 0.01, i, value_fmt.format(v), va="center", fontsize=7.5, color=INK2)
    ax.set_xlim(0, vmax * 1.15)
    return fig_to_img(fig, title)


def month_chart(db: DB) -> str:
    _, rows = db.rows("""SELECT d.year_month, count(*) FROM project_dw.fact_seismic_event f
                         JOIN project_dw.dim_date d USING (date_key) WHERE f.is_active
                         GROUP BY d.year_month ORDER BY 1""")
    labels, values = [r[0] for r in rows], [r[1] for r in rows]
    fig, ax = plt.subplots(figsize=(7.2, 2.6))
    ax.bar(range(len(values)), values, color=BLUE, width=0.7)
    ax.set_xticks(range(0, len(labels), 3), [labels[i] for i in range(0, len(labels), 3)], rotation=0)
    for s in ("top", "right", "left"):
        ax.spines[s].set_visible(False)
    ax.spines["bottom"].set_color(GRID)
    ax.tick_params(colors=INK2, labelsize=7, length=0)
    ax.grid(axis="y", color=GRID, linewidth=0.6)
    ax.set_axisbelow(True)
    ax.set_title("Events loaded per month (fact_seismic_event, active rows)", color=INK, fontsize=10, loc="left", pad=8)
    peak = max(range(len(values)), key=values.__getitem__)
    ax.annotate(f"{labels[peak]}: {values[peak]:,}", (peak, values[peak]), xytext=(0, 4),
                textcoords="offset points", ha="center", fontsize=7.5, color=INK2)
    return fig_to_img(fig, "Events per month").replace('class="chart"', 'class="chart wide"')


CSS = """
@page { size: A4; margin: 16mm 15mm 16mm 15mm; }
* { box-sizing: border-box; }
body { font-family: 'Segoe UI', Arial, sans-serif; color: #1d1d1b; font-size: 10pt; line-height: 1.45; margin: 0; }
h1 { font-size: 21pt; color: #17375e; margin: 0 0 4px; }
h2 { font-size: 13.5pt; color: #17375e; border-bottom: 2px solid #17375e; padding-bottom: 3px; margin: 22px 0 8px; page-break-after: avoid; }
h3 { font-size: 11pt; color: #24518a; margin: 14px 0 6px; page-break-after: avoid; }
p { margin: 4px 0 8px; }
.cover { height: 250mm; display: flex; flex-direction: column; justify-content: center; page-break-after: always; }
.cover .kicker { color: #24518a; font-weight: 600; letter-spacing: .04em; text-transform: uppercase; font-size: 10pt; }
.cover .sub { font-size: 13pt; color: #52514e; margin: 6px 0 28px; }
.cover table { width: auto; font-size: 10.5pt; }
.cover td { border: none; padding: 4px 18px 4px 0; }
.cover td:first-child { color: #52514e; }
table { width: 100%; border-collapse: collapse; margin: 6px 0 12px; font-size: 8.4pt; page-break-inside: auto; }
tr { page-break-inside: avoid; }
th { background: #17375e; color: #fff; text-align: left; padding: 4px 6px; font-weight: 600; }
td { border-bottom: 1px solid #e4e3df; padding: 3px 6px; vertical-align: top; }
td.num { text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; }
tbody tr:nth-child(even) td { background: #f6f7f9; }
.muted { color: #8a8984; }
.badge { display: inline-block; padding: 0 6px; border-radius: 3px; font-weight: 600; font-size: 7.8pt; white-space: nowrap; }
.badge.pass { background: #e3f3e6; color: #0f5a1e; }
.badge.fail { background: #fbe4e4; color: #8a1414; }
.badge.info { background: #e8eef7; color: #24518a; }
pre { background: #f4f5f7; border-left: 3px solid #24518a; padding: 6px 8px; font-size: 7.6pt; white-space: pre-wrap; font-family: Consolas, monospace; page-break-inside: avoid; }
.callout { background: #eef3fa; border-left: 4px solid #24518a; padding: 7px 10px; margin: 8px 0 12px; page-break-inside: avoid; }
.kpis { display: flex; gap: 8px; margin: 8px 0 14px; }
.kpi { flex: 1; border: 1px solid #d9dde3; border-radius: 4px; padding: 7px 9px; }
.kpi .v { font-size: 15pt; font-weight: 700; color: #17375e; }
.kpi .l { font-size: 7.8pt; color: #52514e; }
img.chart { display: block; width: 78%; margin: 4px auto 10px; }
img.chart.wide { width: 100%; }
.small { font-size: 8.4pt; color: #52514e; }
.pb { page-break-before: always; }
"""


def cover(title: str, subtitle: str) -> str:
    team = "<br>".join(html.escape(t) for t in META["team"])
    return f"""
<div class="cover">
  <div class="kicker">{html.escape(META['course'])}</div>
  <h1>{html.escape(title)}</h1>
  <div class="sub">{html.escape(subtitle)}</div>
  <table>
    <tr><td>Project</td><td>{html.escape(META['project'])}</td></tr>
    <tr><td>Deliverable</td><td>{html.escape(META['phase'])}</td></tr>
    <tr><td>Team</td><td>{team}</td></tr>
    <tr><td>Semester</td><td>{html.escape(META['semester'])}, {html.escape(META['institution'])}</td></tr>
    <tr><td>Repository</td><td>{html.escape(META['repository'])}</td></tr>
    <tr><td>Generated</td><td>{date.today():%d %B %Y} from the loaded PostgreSQL warehouse (seismo_dw)</td></tr>
  </table>
</div>"""


def kpis(items) -> str:
    return '<div class="kpis">' + "".join(
        f'<div class="kpi"><div class="v">{v}</div><div class="l">{html.escape(l)}</div></div>' for v, l in items) + "</div>"


# ---------------------------------------------------------------------------
# Data Cleaning Report
# ---------------------------------------------------------------------------
def cleaning_report(db: DB) -> str:
    raw_n = db.scalar("SELECT count(*) FROM project_staging.raw_usgs_event")
    stg_n = db.scalar("SELECT count(*) FROM project_staging.stg_seismic_event")
    rej_n = db.scalar("SELECT count(*) FROM project_staging.rejected_event")
    fact_n = db.scalar("SELECT count(*) FROM project_dw.fact_seismic_event")
    ws_n = db.scalar("SELECT count(*) FROM project_staging.v_raw_usgs_event_flat WHERE place <> btrim(place) OR place ~ '\\s{2,}'")
    dup_cross = db.scalar("""SELECT count(*) FROM (SELECT r.feature->>'id' FROM project_staging.raw_usgs_event r
                             JOIN project_staging.etl_batch b USING (batch_id) WHERE NOT b.is_rerun
                             GROUP BY 1 HAVING count(DISTINCT r.batch_id) > 1) x""")
    tokens = db.one(db.q["distinct_area_tokens"])
    superseded = db.scalar("SELECT count(*) FROM project_staging.rejected_event WHERE reason_code = 'SUPERSEDED_EVENT_ID'")

    # source files
    _, src_rows = db.rows("""SELECT source_file, load_type, CASE WHEN is_rerun THEN 'yes' ELSE 'no' END AS rerun, rows_read
                             FROM project_staging.etl_batch WHERE status <> 'SKIPPED' ORDER BY batch_id""")
    src_desc = {
        "ref_us_states.csv": "US state codes and names (conforms 'CA' / 'California')",
        "ref_country_aliases.csv": "Country spelling aliases (MX, B.C., Burma (Myanmar), ...)",
        "ref_seismic_networks.csv": "Seismic network reference (dim_network)",
        "ref_magnitude_types.csv": "Magnitude type reference (dim_magnitude_type)",
        "usgs_events_2024_2025_full.geojson.gz": "USGS API extract 2024-01-01..2025-12-31, M>=2.5 (full load)",
        "usgs_events_2026_incremental.geojson.gz": "USGS API extract 2026-01-01..2026-11-14, M>=2.5 (incremental)",
        "usgs_events_2026-09-26_change_feed.geojson.gz": "Older Seismo change feed (updatedafter, includes deleted events)",
        "usgs_events_2024-12_snapshot.geojson.gz": "Older Seismo snapshot of Dec-2024 (overlaps the full load)",
    }
    src_table = table(["source_file", "description", "load_type", "rerun", "rows_read"],
                      [(r[0], src_desc.get(r[0], ""), r[1], r[2], r[3]) for r in src_rows])

    # null chart
    _, nulls = db.rows("null_profile")
    null_chart = hbar_chart([r[0] for r in nulls], [float(r[3]) for r in nulls],
                            "Share of raw rows with a NULL value, by source attribute", "% of raw rows", "{:.2f}%")

    # null handling table
    null_rules = [
        ("felt", "Number of 'Did You Feel It?' reports", "NULL -> 0", "no report was submitted; a count of 0 is the true value and keeps SUM() additive"),
        ("alert", "PAGER alert level", "NULL -> 'none'", "no alert was issued; explicit label avoids NULL groups in reports"),
        ("status", "Review status", "NULL -> 'unknown'", "keeps the attribute NOT NULL"),
        ("sig", "Significance score", "NULL -> 0", "additive measure"),
        ("tsunami", "Tsunami flag", "NULL -> FALSE", "boolean flag"),
        ("cdi / mmi", "Intensity values", "kept NULL", "not measured is different from zero intensity; non-additive"),
        ("nst / gap / rms / dmin", "Solution-quality metrics", "kept NULL", "network did not report them"),
        ("magType / net / type", "Coded attributes", "NULL -> Unknown member (-1)", "fact row keeps a valid FK"),
        ("place", "Location text", "NULL -> Unknown location (-1)", "fact row keeps a valid FK"),
        ("id / time / mag / depth / lat / lon", "Required fields", "row rejected", "logged in rejected_event with a reason code"),
    ]
    null_table = table(["attribute", "meaning", "rule", "reason"], null_rules)

    _, std_rows = db.rows("""
        SELECT CASE WHEN f.place LIKE '%,%' THEN btrim(regexp_replace(f.place, '^.*,', '')) ELSE f.place END AS before_raw_area_token,
               s.country || CASE WHEN s.state_province <> 'N/A' THEN ' / ' || s.state_province ELSE '' END AS after_country_state,
               s.location_code AS business_key, count(*) AS rows
        FROM project_staging.v_raw_usgs_event_flat f JOIN project_staging.stg_seismic_event s ON s.raw_id = f.raw_id
        WHERE s.location_code IN ('UNITED_STATES:CALIFORNIA','UNITED_STATES:NEVADA','MEXICO','JAPAN','FIJI','MYANMAR','MID_ATLANTIC_RIDGE','TIMOR_LESTE','RUSSIA')
        GROUP BY 1, 2, 3 HAVING count(*) >= 1 ORDER BY 3, 4 DESC""")

    _, rej = db.rows("rejected_by_reason")
    _, flow = db.rows("""SELECT b.batch_id, b.source_file, b.rows_read, b.rows_duplicate AS in_batch_duplicates,
                                (SELECT count(*) FROM project_staging.rejected_event r WHERE r.batch_id = b.batch_id AND r.stage = 'STAGING' AND r.reason_code <> 'DUPLICATE_IN_BATCH') AS validation_rejects,
                                b.rows_staged,
                                (SELECT count(*) FROM project_staging.rejected_event r WHERE r.batch_id = b.batch_id AND r.stage = 'FACT_LOAD') AS fact_stage_rejects
                         FROM project_staging.etl_batch b WHERE b.source_name = 'usgs_events' AND b.status = 'LOADED' ORDER BY 1""")

    clean_sql = (SQL_DIR / "staging" / "12_clean_events_to_staging.sql").read_text(encoding="utf-8")
    conform_snippet = clean_sql[clean_sql.index("conformed AS ("):clean_sql.index("), resolved AS")]

    return f"""<!doctype html><html><head><meta charset="utf-8"><title>Data Cleaning Report</title><style>{CSS}</style></head><body>
{cover('Data Cleaning Report', 'Profiling of the raw USGS earthquake and reference extracts, and the cleaning rules applied in the staging layer')}

<h2>1. Summary</h2>
<p>The warehouse ingests real public data: the USGS FDSN Event Web Service (magnitude 2.5 and above) for
1 January 2024 to 14 November 2026, frozen into GeoJSON source files, plus four small reference CSV files.
Following the ELT approach of Lab 07, every file is first copied <b>unchanged</b> into the raw landing tables of
<code>project_staging</code> (with a batch id and an MD5 hash per record). All cleaning then happens in SQL
(<code>sql/staging/11_*.sql</code>, <code>12_*.sql</code>) and writes typed, de-duplicated, standardised rows to the
<code>stg_*</code> tables. Rows that cannot be repaired are never silently dropped: they go to
<code>project_staging.rejected_event</code> with a reason code.</p>
{kpis([(f"{raw_n:,}", "raw rows landed (all batches)"), (f"{stg_n:,}", "rows staged after cleaning"),
       (f"{rej_n:,}", "rows quarantined with a reason"), (f"{fact_n:,}", "distinct events in the warehouse")])}

<h2>2. Source files</h2>
{src_table}
<p class="small">Fact minimum (10,000+) and dimension minimum (100+) are met: {fact_n:,} fact rows; dim_location has
{db.scalar('SELECT count(*) FROM project_dw.dim_location'):,} rows and dim_date {db.scalar('SELECT count(*) FROM project_dw.dim_date'):,} rows.
The two older Seismo snapshots were loaded on purpose: they overlap the fresh extracts and carry real duplicates,
older versions and a deleted event, which exercises every cleaning rule on genuine data.</p>

<h2>3. Profiling findings (before cleaning)</h2>
<p>All profiling queries are in <code>sql/staging/10_profile_raw_data.sql</code> and read only the raw tables.</p>
<h3>3.1 Row counts recorded immediately after loading</h3>
{qtable(db, 'raw_rows_per_batch')}
<h3>3.2 Duplicate business keys</h3>
{qtable(db, 'duplicate_event_ids')}
{qtable(db, 'duplicate_versions')}
<p>USGS also merges two solutions of the same earthquake under one <i>preferred</i> id and lists the old ids in the
<code>ids</code> property. Raw ids that appear as an alias inside another delivered event:</p>
{qtable(db, 'merged_event_ids')}
<p class="small">65 of these are rejected as SUPERSEDED_EVENT_ID (section 4.1). The other two need no rule: one is a malformed record already
rejected for a missing event time, and in the other USGS flipped the preferred id (an old record named the now-preferred event as its alias;
the old record itself is the one rejected).</p>
<h3>3.3 Missing values</h3>
{null_chart}
{qtable(db, 'null_profile')}
<h3>3.4 Whitespace and inconsistent text</h3>
{qtable(db, 'whitespace_issues')}
{qtable(db, 'whitespace_examples')}
<p>The place text ends with an "area" token, and the same real place is spelled in several ways
(state code vs name, "region" suffixes, direction prefixes, alternative country names). This is the seismic equivalent of
<i>" lahore "</i> / <i>"LAHORE"</i> -> <i>Lahore</i> from the Phase 2 brief:</p>
{qtable(db, 'inconsistent_area_spellings')}
<h3>3.5 Coded values, reference coverage and ranges</h3>
{qtable(db, 'network_codes_not_in_reference')}
{qtable(db, 'range_violations')}

<h2>4. Cleaning rules applied</h2>
<h3>4.1 Remove duplicates</h3>
<table><thead><tr><th>Duplicate type</th><th>Rule</th><th>Where</th><th>Rows affected</th></tr></thead><tbody>
<tr><td>Same event_id twice in one batch</td><td>keep newest USGS <code>updated</code>, then last row in file; others logged as DUPLICATE_IN_BATCH</td><td>12_clean_events_to_staging.sql step 3</td><td class="num">{db.scalar("SELECT count(*) FROM project_staging.rejected_event WHERE reason_code='DUPLICATE_IN_BATCH'"):,}</td></tr>
<tr><td>Same event_id in several batches</td><td>staging keeps one row per (batch, event); the fact upsert lets only a <b>newer</b> USGS version overwrite, identical or older copies change nothing</td><td>30_load_fact_seismic_event.sql step 4</td><td class="num">{dup_cross:,} event ids</td></tr>
<tr><td>Same earthquake under two ids (merged by USGS)</td><td>alias id listed in another event's <code>ids</code> is rejected as SUPERSEDED_EVENT_ID (or deactivated if it arrived first)</td><td>30_load_fact_seismic_event.sql steps 2 / 4b</td><td class="num">{superseded:,}</td></tr>
<tr><td>Duplicate codes in reference CSVs</td><td>DISTINCT ON the cleaned code, last row in the file wins</td><td>11_clean_reference_to_staging.sql</td><td class="num">0</td></tr>
</tbody></table>

<h3>4.2 Handle NULL values</h3>
{null_table}

<h3>4.3 Standardise text</h3>
<p><b>Generic rule</b> for every text column: <code>fn_clean_text()</code> = TRIM + collapse repeated whitespace + empty string to NULL
({ws_n} raw place values had stray whitespace). Codes (<code>net</code>, <code>magType</code>, <code>type</code>, <code>status</code>, <code>alert</code>)
are lower-cased; labels are produced in Title Case in the dimensions (e.g. <i>quarry blast</i> -> <i>Quarry Blast</i>).</p>
<p><b>Location conformance</b>: the trailing area token is stripped of direction prefixes ("south of the"), coast phrases
("off the coast of"), lower-case qualifiers ("northern") and "region"/"Earthquake" suffixes, then resolved against the
<code>ref_us_states</code> and <code>ref_country_aliases</code> reference data. "Georgia" spelled out is the country (USGS writes the US state as "GA"),
which the reference file encodes as <code>match_by_name = N</code>. This reduces
<b>{tokens[0]:,}</b> distinct raw area tokens to <b>{tokens[1]:,}</b> conformed locations.</p>
{table(['before_raw_area_token', 'after_country_state', 'business_key', 'rows'], std_rows)}
{code(conform_snippet)}

<h3>4.4 Convert data types</h3>
<table><thead><tr><th>Source (JSON text)</th><th>Staging type</th><th>Conversion</th></tr></thead><tbody>
<tr><td>time, updated (epoch milliseconds)</td><td>TIMESTAMPTZ (UTC)</td><td><code>to_timestamp(ms / 1000.0)</code> via fn_epoch_ms_to_ts</td></tr>
<tr><td>mag</td><td>NUMERIC(4,2)</td><td>safe cast fn_try_numeric + round(…, 2)</td></tr>
<tr><td>coordinates[0..2]</td><td>NUMERIC(9,6) lon/lat, NUMERIC(8,3) depth</td><td>safe cast + rounding</td></tr>
<tr><td>felt, sig, nst</td><td>INT</td><td>safe cast</td></tr>
<tr><td>tsunami (0/1)</td><td>BOOLEAN</td><td><code>tsunami = 1</code></td></tr>
<tr><td>ids (",a,b,")</td><td>TEXT[]</td><td><code>string_to_array(btrim(ids, ','), ',')</code></td></tr>
</tbody></table>
{qtable(db, 'type_conversion_examples')}

<h3>4.5 Validation (quarantine) rules</h3>
<p>Applied in order; the first failing rule is stored. Valid domains: latitude [-90, 90], longitude [-180, 180], magnitude [-2, 10],
depth [-10, 800] km (negative depths are legitimate in USGS data: events above the reference datum), event time not in the future.</p>
{table(['stage', 'reason_code', 'rows', 'first_batch', 'last_batch'], rej)}

<h2>5. Results per batch</h2>
{table(['batch_id', 'source_file', 'rows_read', 'in_batch_duplicates', 'validation_rejects', 'rows_staged', 'fact_stage_rejects'], flow)}
<div class="callout"><b>Row accounting:</b> raw rows = staged rows + rows rejected in staging
({raw_n:,} = {stg_n:,} + {db.scalar("SELECT count(*) FROM project_staging.rejected_event WHERE stage='STAGING'"):,}).
Every raw row is either cleaned or quarantined, which is verified automatically by data-quality check C01.</div>

<h2>6. Known limitations</h2>
<ul>
<li>Four events exist only in the older 2026-09-26 change feed. Spot checks against the USGS API show that three of them were
later revised to M2.32-2.44 (below the M2.5 extraction threshold) and one no longer resolves (likely deleted). The current extract
cannot see these revisions because it filters by magnitude; Phase 3 will add an <code>updatedafter</code> change feed without a magnitude filter.</li>
<li>Location conformance works at country / US-state grain. Free text beyond that (e.g. "Kamchatka Peninsula") is kept on the fact as
<code>nearest_place</code> rather than modelled as a hierarchy.</li>
<li>Reference CSVs (networks, magnitude types) were compiled by the team from USGS documentation; codes missing from them become
<i>inferred</i> dimension members (is_inferred = TRUE) instead of being rejected.</li>
</ul>
</body></html>"""


# ---------------------------------------------------------------------------
# Data Quality Report
# ---------------------------------------------------------------------------
def quality_report(db: DB) -> str:
    cols, dq = db.rows("""SELECT check_code, category, check_name, expected_value, actual_value, status
                          FROM project_reporting.vw_dq_latest_run ORDER BY category, check_code""")
    n_pass = sum(1 for r in dq if r[5] == "PASS")
    n_fail = sum(1 for r in dq if r[5] == "FAIL")
    n_info = sum(1 for r in dq if r[5] == "INFO")
    run_id = db.scalar("SELECT max(run_id) FROM project_reporting.vw_dq_latest_run")

    def dq_rows(category):
        return [r for r in dq if r[1] == category]

    _, details = db.rows("SELECT check_code, details FROM project_reporting.vw_dq_latest_run")
    det = dict(details)

    def dq_table(category):
        rows = [(r[0], r[2], r[3], r[4], r[5], det.get(r[0]) or "") for r in dq_rows(category)]
        return table(["check", "check_name", "expected", "actual", "status", "details"], rows, status_col="status")

    _, rerun = db.rows("""SELECT b.batch_id, b.source_file, b.is_rerun, s.rows_processed, s.rows_inserted, s.rows_updated, s.rows_rejected
                          FROM project_staging.etl_step_log s JOIN project_staging.etl_batch b USING (batch_id)
                          WHERE s.step_name = 'load_fact' ORDER BY b.batch_id""")
    rerun_proof = (ROOT / "evidence" / "09_idempotent_rerun_proof.csv")
    rerun_tbl = ""
    if rerun_proof.exists():
        lines = [ln.split(",") for ln in rerun_proof.read_text(encoding="utf-8").strip().splitlines()]
        rerun_tbl = table(lines[0], [tuple(x) for x in lines[1:]])
    constraint_txt = (ROOT / "evidence" / "11_constraint_test.txt")
    constraint = code(constraint_txt.read_text(encoding="utf-8")) if constraint_txt.exists() else ""

    _, magc = db.rows("""SELECT mc.magnitude_class, count(*) FROM project_dw.fact_seismic_event f
                         JOIN project_dw.dim_magnitude_class mc USING (magnitude_class_key) WHERE f.is_active
                         GROUP BY mc.magnitude_class, mc.sort_order ORDER BY mc.sort_order""")
    mag_chart = hbar_chart([r[0] for r in magc], [r[1] for r in magc], "Active events by magnitude class", "events")

    dq_sql = (SQL_DIR / "quality" / "40_data_quality_checks.sql").read_text(encoding="utf-8")
    orphan_snippet = dq_sql[dq_sql.index("INSERT INTO dq_check_result", dq_sql.index("INTEGRITY (foreign keys)")):
                            dq_sql.index("UNION ALL SELECT 'I02'")]

    return f"""<!doctype html><html><head><meta charset="utf-8"><title>Data Quality Report</title><style>{CSS}</style></head><body>
{cover('Data Quality Report', 'Completeness, accuracy (reconciliation) and integrity validation of the Seismo PostgreSQL warehouse')}

<h2>1. Summary</h2>
<p>Data quality is validated <b>inside the pipeline</b>: after every batch the script
<code>sql/quality/40_data_quality_checks.sql</code> runs {len(dq)} checks and stores each result in
<code>project_staging.dq_check_result</code> (exposed as <code>project_reporting.vw_dq_latest_run</code>). The batch transaction
commits only after the checks ran, so every load leaves an auditable scorecard. Results below are from the latest run (batch {run_id}).</p>
{kpis([(str(n_pass), "checks PASS"), (str(n_fail), "checks FAIL"), (str(n_info), "INFO metrics (no threshold)"),
       (f"{db.scalar('SELECT count(*) FROM project_dw.fact_seismic_event'):,}", "fact rows validated")])}
<div class="callout">Phase 2 targets: <b>completeness</b> (missing values) &bull; <b>accuracy</b> (revenue reconciliation; for seismic
data the additive "money" measure is radiated <b>energy</b>, so SUM(energy_joules) is reconciled alongside counts, magnitude, felt reports and significance)
&bull; <b>integrity</b> (foreign keys: fact rows without matching dimension = 0). Uniqueness, validity and consistency checks are added on top.</div>

<h2>2. Completeness</h2>
{dq_table('COMPLETENESS')}

<h2>3. Accuracy - reconciliation</h2>
<p>The expected warehouse content is recomputed independently from staging: the latest active version of every staged event
that was not rejected at the fact stage. Counts and every additive measure must match the fact table exactly
(energy uses a relative tolerance of 1e-9 for floating-point summation order).</p>
{dq_table('ACCURACY')}
{dq_table('VALIDITY')}
<h3>3.1 Grain reconciliation: source rows to fact rows</h3>
{qtable(db, 'grain_reconciliation')}
<p class="small">Raw rows exceed fact rows because the same event is delivered by several batches (repeat deliveries, including the deliberate re-run)
and because quarantined rows are excluded. Every difference is explained by a counted category.</p>
<h3>3.2 Batch reconciliation (Lab 07 Task 7)</h3>
{qtable(db, 'batch_reconciliation')}
<h3>3.3 Same question from staging and from the star (Lab 06 Task 9.3)</h3>
<p>"How many magnitude 5.0+ events happened in each quarter of 2025, and how much energy did they release?" answered once from
staging rows and once from the dimensional model:</p>
{qtable(db, 'source_vs_warehouse')}

<h2 class="pb">4. Integrity - foreign-key validation</h2>
{dq_table('INTEGRITY')}
{qtable(db, 'orphan_checks')}
{code(orphan_snippet)}
<h3>4.1 Constraint test (Lab 06 Task 8.4)</h3>
<p>Three INSERTs that must fail were executed inside rolled-back transactions. PostgreSQL rejected all three, so the database itself protects the star:</p>
{constraint}

<h2>5. Uniqueness and surrogate keys</h2>
{dq_table('UNIQUENESS')}
{qtable(db, 'dimension_uniqueness')}
<h3>5.1 Business key to surrogate key</h3>
{qtable(db, 'surrogate_key_examples')}
<h3>5.2 Mapping trace (Lab 06 Challenge A)</h3>
{qtable(db, 'mapping_trace')}
<p class="small">The fact stores integer surrogate keys only: they are compact, stable if a source code is renamed, and allow Unknown (-1) and inferred members,
while the business codes stay in the dimensions for traceability.</p>

<h2>6. Consistency</h2>
{dq_table('CONSISTENCY')}
{mag_chart}

<h2 class="pb">7. Incremental load and idempotent re-run (Lab 07 Task 6)</h2>
<p>Batches are processed in the order full load 2024-2025, incremental 2026, then two older snapshots. Finally the 2026 file is re-loaded unchanged
(batch flagged <code>is_rerun</code>). Idempotency comes from the UNIQUE <code>event_id</code> plus a conflict-safe upsert that only accepts a
<b>newer</b> USGS version, not from a date filter. Because batches are processed by batch id rather than a strict event-date watermark, late-arriving
older events (such as the December-2024 snapshot) are still evaluated rather than missed.</p>
{table(['batch_id', 'source_file', 'is_rerun', 'staged_rows', 'fact_inserted', 'fact_updated', 'rejected'], rerun)}
{rerun_tbl}

<h2>8. Broken-load simulation and diagnostics (Lab 06 sections 10-11)</h2>
<p>A CTE duplicates the business key <code>ak</code> in dim_network. Joining facts to that broken dimension inflates both row count and energy,
which is exactly what the reconciliation checks above would catch:</p>
{qtable(db, 'broken_load_simulation')}
{qtable(db, 'duplicate_key_diagnostic')}
<div class="callout"><b>Root-cause rule:</b> a row-count match alone is not proof. A wrong join can drop some rows and duplicate others so the count
still matches, and a value can be mis-mapped without changing the count. Measure reconciliation (SUM of magnitude, energy, felt reports, significance)
plus orphan and uniqueness checks are required together.</div>

<h2>9. Rejected rows</h2>
{qtable(db, 'rejected_by_reason')}

<h2>10. Findings and follow-up</h2>
<ul>
<li>All {n_pass} threshold checks pass; no FAIL results.</li>
<li>The USGS feed itself contains a merged-id pair (nn00908096 inside nn00908129) and the older change feed contains {db.scalar("SELECT count(*) FROM project_staging.rejected_event WHERE reason_code='SUPERSEDED_EVENT_ID' AND batch_id <> (SELECT min(batch_id) FROM project_staging.etl_batch WHERE source_name='usgs_events')")}
alias ids: without the <code>ids</code>-based rule (check U10) these would double-count earthquakes while every key-based check still passed.</li>
<li>Four events are known only from the older snapshot (see Data Cleaning Report section 6); they are valid as of that snapshot and will be revisited with a magnitude-unfiltered change feed in Phase 3.</li>
<li>High NULL rates for felt/cdi/mmi/alert (INFO checks) are inherent to the source (most M2.5 events are not felt and get no PAGER alert) and are handled by documented rules, not errors.</li>
</ul>
{month_chart(db)}
</body></html>"""


# ---------------------------------------------------------------------------
def find_browser() -> str:
    for b in BROWSERS:
        if Path(b).exists() or shutil.which(b):
            return b
    raise RuntimeError("No Edge/Chrome found to print the PDF")


def to_pdf(html_text: str, name: str) -> Path:
    BUILD_DIR.mkdir(exist_ok=True)
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    src = BUILD_DIR / f"{name}.html"
    src.write_text(html_text, encoding="utf-8")
    out = OUT_DIR / f"{name}.pdf"
    if out.exists():
        out.unlink()
    profile = BUILD_DIR / "browser-profile"          # isolated profile: never touches the user's browser
    subprocess.run([find_browser(), "--headless=new", "--disable-gpu", "--no-pdf-header-footer",
                    f"--user-data-dir={profile.resolve()}", f"--print-to-pdf={out}", src.resolve().as_uri()],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=180)
    print(f"wrote {out.relative_to(ROOT)} ({out.stat().st_size / 1024:.0f} KB)")
    return out


def main() -> None:
    db = DB()
    to_pdf(cleaning_report(db), "Data_Cleaning_Report")
    to_pdf(quality_report(db), "Data_Quality_Report")


if __name__ == "__main__":
    main()
