"""
generate_pbip.py - writes the Power BI project (PBIP) for the Seismo DW dashboard.

    powerbi/SeismoDW.pbip                 project file (open this in Power BI Desktop)
    powerbi/SeismoDW.SemanticModel/       TMDL semantic model: tables, relationships, DAX measures
    powerbi/SeismoDW.Report/              PBIR report: 3 pages, every visual as JSON

The model imports from the PostgreSQL warehouse (project_dw star + project_reporting
views). Server/database are model parameters (PgServer, PgDatabase), so the same file
works against any copy of the warehouse. After a refresh in Power BI Desktop the file is
saved as powerbi/SeismoDW.pbix (data embedded) for submission.

    python powerbi/generate_pbip.py
"""
from __future__ import annotations

import json
import shutil
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
MODEL = HERE / "SeismoDW.SemanticModel"
REPORT = HERE / "SeismoDW.Report"
T = "\t"

# ---------------------------------------------------------------------------
# semantic model definition
# ---------------------------------------------------------------------------
# (column, dataType, summarizeBy, formatString or None, hidden)
TABLES = {
    "fact_seismic_event": {
        "schema": "project_dw", "item": "fact_seismic_event", "filter_active": True,
        "description": "Fact: one row per active USGS seismic event (grain of the warehouse).",
        "columns": [
            ("event_id", "string", "none", None, False),
            ("date_key", "int64", "none", None, True),
            ("location_key", "int64", "none", None, True),
            ("network_key", "int64", "none", None, True),
            ("magnitude_type_key", "int64", "none", None, True),
            ("event_type_key", "int64", "none", None, True),
            ("magnitude_class_key", "int64", "none", None, True),
            ("depth_class_key", "int64", "none", None, True),
            ("event_hour_utc", "int64", "none", None, False),
            ("latitude", "double", "none", "0.0000", False),
            ("longitude", "double", "none", "0.0000", False),
            ("magnitude", "double", "average", "0.00", False),
            ("depth_km", "double", "average", "0.0", False),
            ("energy_tnt_tons", "double", "sum", "#,0", False),
            ("felt_reports", "int64", "sum", "#,0", False),
            ("significance", "int64", "average", "#,0", False),
            ("alert_level", "string", "none", None, False),
            ("tsunami_flag", "boolean", "none", None, False),
            ("is_significant", "boolean", "none", None, False),
        ],
        "measures": [
            ("Total Events", "COUNTROWS ( fact_seismic_event )", "#,0",
             "Orders KPI equivalent: number of seismic events"),
            ("Energy Released (kt TNT)", "DIVIDE ( SUM ( fact_seismic_event[energy_tnt_tons] ), 1000 )", "#,0",
             "Revenue KPI equivalent: radiated energy in kilotons of TNT"),
            ("Affected Locations", "DISTINCTCOUNT ( fact_seismic_event[location_key] )", "#,0",
             "Customers KPI equivalent: distinct countries / US states with events"),
            ("Avg Magnitude", "AVERAGE ( fact_seismic_event[magnitude] )", "0.00", None),
            ("Max Magnitude", "MAX ( fact_seismic_event[magnitude] )", "0.0", None),
            ("Strong Events (M5+)", "CALCULATE ( [Total Events], fact_seismic_event[magnitude] >= 5 )", "#,0", None),
            ("Felt Reports", "SUM ( fact_seismic_event[felt_reports] )", "#,0", None),
            # Same-period comparison: latest year with data, 1 Jan -> last loaded day, vs the same
            # calendar window one year earlier (2026 is a partial year, so full-year YoY would mislead)
            ("Events YoY % (same period)",
             "VAR lastDay = CALCULATE ( MAX ( dim_date[full_date] ), fact_seismic_event )\n" + T * 3 +
             "VAR y = YEAR ( lastDay )\n" + T * 3 +
             "VAR cur = CALCULATE ( [Total Events], DATESBETWEEN ( dim_date[full_date], DATE ( y, 1, 1 ), lastDay ) )\n" + T * 3 +
             "VAR prev = CALCULATE ( [Total Events], DATESBETWEEN ( dim_date[full_date], DATE ( y - 1, 1, 1 ), EDATE ( lastDay, -12 ) ) )\n" + T * 3 +
             "RETURN DIVIDE ( cur - prev, prev )", "+0.0%;-0.0%;0.0%",
             "Events in the latest year to date vs the same calendar window one year earlier"),
            ("Strong Events YoY % (same period)",
             "VAR lastDay = CALCULATE ( MAX ( dim_date[full_date] ), fact_seismic_event )\n" + T * 3 +
             "VAR y = YEAR ( lastDay )\n" + T * 3 +
             "VAR cur = CALCULATE ( [Strong Events (M5+)], DATESBETWEEN ( dim_date[full_date], DATE ( y, 1, 1 ), lastDay ) )\n" + T * 3 +
             "VAR prev = CALCULATE ( [Strong Events (M5+)], DATESBETWEEN ( dim_date[full_date], DATE ( y - 1, 1, 1 ), EDATE ( lastDay, -12 ) ) )\n" + T * 3 +
             "RETURN DIVIDE ( cur - prev, prev )", "+0.0%;-0.0%;0.0%",
             "M5+ events in the latest year to date vs the same calendar window one year earlier"),
            ("Strong Event Share", "DIVIDE ( [Strong Events (M5+)], [Total Events] )", "0.00%", None),
        ],
    },
    "dim_date": {
        "schema": "project_dw", "item": "dim_date", "date_table": True,
        "description": "Calendar dimension (smart key YYYYMMDD).",
        "columns": [
            ("date_key", "int64", "none", None, True),
            ("full_date", "dateTime", "none", "yyyy-mm-dd", False),
            ("year", "int64", "none", None, False),
            ("quarter_label", "string", "none", None, False),
            ("month", "int64", "none", None, False),
            ("month_name", "string", "none", None, False),
            ("year_month", "string", "none", None, False),
            ("day_name", "string", "none", None, False),
            ("is_weekend", "boolean", "none", None, False),
        ],
    },
    "dim_location": {
        "schema": "project_dw", "item": "dim_location",
        "description": "Location dimension (country / US state) - the 'customer' of the brief.",
        "columns": [
            ("location_key", "int64", "none", None, True),
            ("location_code", "string", "none", None, False),
            ("location_label", "string", "none", None, False),
            ("country", "string", "none", None, False),
            ("state_province", "string", "none", None, False),
            ("location_type", "string", "none", None, False),
        ],
    },
    "dim_network": {
        "schema": "project_dw", "item": "dim_network",
        "description": "Seismic network (SCD Type 2: one row per version).",
        "columns": [
            ("network_key", "int64", "none", None, True),
            ("network_code", "string", "none", None, False),
            ("network_name", "string", "none", None, False),
            ("network_type", "string", "none", None, False),
            ("version_no", "int64", "none", None, False),
            ("is_current", "boolean", "none", None, False),
        ],
    },
    "dim_magnitude_class": {
        "schema": "project_dw", "item": "dim_magnitude_class",
        "description": "Richter magnitude classes - the 'product' of the brief.",
        "columns": [
            ("magnitude_class_key", "int64", "none", None, True),
            ("magnitude_class", "string", "none", None, False),
            ("magnitude_range", "string", "none", None, False),
            ("sort_order", "int64", "none", None, True),
        ],
        "sort_by": {"magnitude_class": "sort_order"},
    },
    "dim_event_type": {
        "schema": "project_dw", "item": "dim_event_type",
        "description": "Event type (earthquake, blasts ...) - the 'category' of the brief.",
        "columns": [
            ("event_type_key", "int64", "none", None, True),
            ("event_type_label", "string", "none", None, False),
            ("event_origin", "string", "none", None, False),
        ],
    },
    "dim_depth_class": {
        "schema": "project_dw", "item": "dim_depth_class",
        "description": "Focal depth classes.",
        "columns": [
            ("depth_class_key", "int64", "none", None, True),
            ("depth_class", "string", "none", None, False),
            ("sort_order", "int64", "none", None, True),
        ],
        "sort_by": {"depth_class": "sort_order"},
    },
    "vw_monthly_sales": {
        "schema": "project_reporting", "item": "vw_monthly_sales",
        "description": "Reporting view: month | events | energy | growth.",
        "columns": [
            ("month_start", "dateTime", "none", "mmm yyyy", False),
            ("year_month", "string", "none", None, False),
            ("events", "int64", "sum", "#,0", False),
            ("total_energy_tnt_tons", "double", "sum", "#,0", False),
            ("mom_event_growth_pct", "double", "none", "0.0", False),
            ("yoy_event_growth_pct", "double", "none", "0.0", False),
            ("events_3m_moving_avg", "double", "none", "#,0", False),
            ("active_locations", "int64", "none", "#,0", False),
        ],
    },
    "vw_customer_analysis": {
        "schema": "project_reporting", "item": "vw_customer_analysis",
        "description": "Reporting view: one row per location with RFM activity segment.",
        "columns": [
            ("location_key", "int64", "none", None, True),
            ("location_label", "string", "none", None, False),
            ("location_type", "string", "none", None, False),
            ("events", "int64", "sum", "#,0", False),
            ("total_energy_tnt_tons", "double", "sum", "#,0", False),
            ("max_magnitude", "double", "max", "0.0", False),
            ("recency_days", "int64", "none", "#,0", False),
            ("rfm_code", "int64", "none", None, False),
            ("activity_segment", "string", "none", None, False),
        ],
        "measures": [
            ("Segment Locations", "COUNTROWS ( vw_customer_analysis )", "#,0", None),
        ],
    },
    "vw_product_performance": {
        "schema": "project_reporting", "item": "vw_product_performance",
        "description": "Reporting view: magnitude class (product) within event type (category).",
        "columns": [
            ("category", "string", "none", None, False),
            ("product", "string", "none", None, False),
            ("product_sort", "int64", "none", None, True),
            ("events", "int64", "sum", "#,0", False),
            ("total_energy_tnt_tons", "double", "sum", "#,0", False),
            ("share_of_energy_pct", "double", "sum", "0.00", False),
            ("avg_depth_km", "double", "average", "0.0", False),
        ],
        "sort_by": {"product": "product_sort"},
    },
    "vw_strong_event_growth": {
        "schema": "project_reporting", "item": "vw_strong_event_growth",
        "description": "Reporting view: M5+ events per location, same calendar window this year vs last year.",
        "columns": [
            ("location_label", "string", "none", None, False),
            ("location_type", "string", "none", None, False),
            ("strong_prev_ytd", "int64", "sum", "#,0", False),
            ("strong_curr_ytd", "int64", "sum", "#,0", False),
            ("growth_pct", "double", "none", "0.0", False),
            ("is_material", "boolean", "none", None, False),
        ],
        "measures": [
            ("Strong M5+ last year (same period)", "SUM ( vw_strong_event_growth[strong_prev_ytd] )", "#,0", None),
            ("Strong M5+ this year (to date)", "SUM ( vw_strong_event_growth[strong_curr_ytd] )", "#,0", None),
        ],
    },
}

RELATIONSHIPS = [
    ("fact_seismic_event", "date_key", "dim_date", "date_key"),
    ("fact_seismic_event", "location_key", "dim_location", "location_key"),
    ("fact_seismic_event", "network_key", "dim_network", "network_key"),
    ("fact_seismic_event", "magnitude_class_key", "dim_magnitude_class", "magnitude_class_key"),
    ("fact_seismic_event", "event_type_key", "dim_event_type", "event_type_key"),
    ("fact_seismic_event", "depth_class_key", "dim_depth_class", "depth_class_key"),
]

# static decision table shown on page 3 (filled from the Business Insights analysis)
DECISIONS_FILE = HERE / "decisions.json"


def q(name: str) -> str:
    """TMDL object name quoting."""
    return f"'{name}'" if any(c in name for c in " ()%+-/.") else name


def m_partition(tbl: str, spec: dict) -> str:
    steps = [
        "let",
        f'{T}Source = PostgreSQL.Database(PgServer, PgDatabase),',
        f'{T}Nav = Source{{[Schema="{spec["schema"]}", Item="{spec["item"]}"]}}[Data],',
        f'{T}Kept = Table.SelectColumns(Nav, {{{", ".join(json.dumps(c[0]) for c in spec["columns"])}}})',
    ]
    if spec.get("filter_active"):
        steps[-1] = f'{T}Active = Table.SelectRows(Nav, each [is_active] = true),'
        steps.append(f'{T}Kept = Table.SelectColumns(Active, {{{", ".join(json.dumps(c[0]) for c in spec["columns"])}}})')
    steps += ["in", f"{T}Kept"]
    return "\n".join(T * 4 + s for s in steps)


def table_tmdl(name: str, spec: dict) -> str:
    out = [f"table {name}", f"{T}lineageTag: {uuid.uuid5(uuid.NAMESPACE_URL, name)}", ""]
    if spec.get("date_table"):
        out.insert(1, f"{T}dataCategory: Time")
    for mname, expr, fmt, desc in spec.get("measures", []):
        if desc:
            out.append(f"{T}/// {desc}")
        if "\n" in expr:
            out.append(f"{T}measure {q(mname)} =")
            out += [T * 3 + line.lstrip("\t") for line in expr.split("\n")]
        else:
            out.append(f"{T}measure {q(mname)} = {expr}")
        out.append(f"{T}{T}formatString: {fmt}")
        out.append(f"{T}{T}lineageTag: {uuid.uuid5(uuid.NAMESPACE_URL, name + '.' + mname)}")
        out.append("")
    for col, dtype, summ, fmt, hidden in spec["columns"]:
        out.append(f"{T}column {q(col)}")
        out.append(f"{T}{T}dataType: {dtype}")
        if fmt:
            out.append(f"{T}{T}formatString: {fmt}")
        if hidden:
            out.append(f"{T}{T}isHidden")
        if spec.get("date_table") and col == "full_date":
            out.append(f"{T}{T}isKey")
        out.append(f"{T}{T}lineageTag: {uuid.uuid5(uuid.NAMESPACE_URL, name + '.' + col)}")
        out.append(f"{T}{T}summarizeBy: {summ}")
        out.append(f"{T}{T}sourceColumn: {col}")
        if col in spec.get("sort_by", {}):
            out.append(f"{T}{T}sortByColumn: {spec['sort_by'][col]}")
        out.append("")
    out.append(f"{T}partition {name} = m")
    out.append(f"{T}{T}mode: import")
    out.append(f"{T}{T}source =")
    out.append(m_partition(name, spec))
    out.append("")
    return "\n".join(out)


def decisions_table_tmdl() -> str:
    rows = json.loads(DECISIONS_FILE.read_text(encoding="utf-8"))
    cols = ["priority", "decision", "evidence"]

    def lit(s):
        return '"' + str(s).replace('"', '""') + '"'

    body = ", ".join("{" + ", ".join([str(r["priority"]), lit(r["decision"]), lit(r["evidence"])]) + "}" for r in rows)
    expr = (f'#table(type table [priority = Int64.Type, decision = text, evidence = text], {{{body}}})')
    out = ["table Decisions", f"{T}lineageTag: {uuid.uuid5(uuid.NAMESPACE_URL, 'Decisions')}", ""]
    for c in cols:
        out += [f"{T}column {c}", f"{T}{T}dataType: {'int64' if c == 'priority' else 'string'}",
                f"{T}{T}lineageTag: {uuid.uuid5(uuid.NAMESPACE_URL, 'Decisions.' + c)}",
                f"{T}{T}summarizeBy: none", f"{T}{T}sourceColumn: {c}", ""]
    out += [f"{T}partition Decisions = m", f"{T}{T}mode: import", f"{T}{T}source =",
            T * 4 + "let", T * 5 + f"Source = {expr}", T * 4 + "in", T * 5 + "Source", ""]
    return "\n".join(out)


def write_model() -> None:
    d = MODEL / "definition"
    if d.exists():
        shutil.rmtree(d)
    (d / "tables").mkdir(parents=True)
    (MODEL / "definition.pbism").write_text(json.dumps({"version": "4.2", "settings": {}}, indent=2), encoding="utf-8")
    (d / "database.tmdl").write_text("database\n\tcompatibilityLevel: 1606\n", encoding="utf-8")
    names = list(TABLES) + ["Decisions"]
    model = ["model Model", f"{T}culture: en-US", f"{T}defaultPowerBIDataSourceVersion: powerBI_V3",
             f"{T}discourageImplicitMeasures", f"{T}sourceQueryCulture: en-US", f"{T}valueFilterBehavior: independent",
             f"{T}dataAccessOptions", f"{T}{T}legacyRedirects", f"{T}{T}returnErrorValuesAsNull", "",
             "annotation __PBI_TimeIntelligenceEnabled = 0", "",
             f"annotation PBI_QueryOrder = {json.dumps(['PgServer', 'PgDatabase'] + names)}", ""]
    model += [f"ref table {n}" for n in names]
    model += ["", "ref cultureInfo en-US", ""]
    (d / "model.tmdl").write_text("\n".join(model), encoding="utf-8")
    (d / "expressions.tmdl").write_text(
        'expression PgServer = "localhost:5433" meta [IsParameterQuery=true, Type="Text", IsParameterQueryRequired=true]\n'
        f"{T}lineageTag: {uuid.uuid5(uuid.NAMESPACE_URL, 'PgServer')}\n\n"
        f"{T}annotation PBI_ResultType = Text\n\n"
        'expression PgDatabase = "seismo_dw" meta [IsParameterQuery=true, Type="Text", IsParameterQueryRequired=true]\n'
        f"{T}lineageTag: {uuid.uuid5(uuid.NAMESPACE_URL, 'PgDatabase')}\n\n"
        f"{T}annotation PBI_ResultType = Text\n", encoding="utf-8")
    for name, spec in TABLES.items():
        (d / "tables" / f"{name}.tmdl").write_text(table_tmdl(name, spec), encoding="utf-8")
    (d / "tables" / "Decisions.tmdl").write_text(decisions_table_tmdl(), encoding="utf-8")
    rel = []
    for ft, fc, tt, tc in RELATIONSHIPS:
        rel += [f"relationship {uuid.uuid5(uuid.NAMESPACE_URL, ft + fc)}", f"{T}fromColumn: {ft}.{fc}",
                f"{T}toColumn: {tt}.{tc}", ""]
    (d / "relationships.tmdl").write_text("\n".join(rel), encoding="utf-8")
    (d / "cultures").mkdir()
    (d / "cultures" / "en-US.tmdl").write_text("cultureInfo en-US\n", encoding="utf-8")
    print("semantic model written")


# ---------------------------------------------------------------------------
# report definition (PBIR)
# ---------------------------------------------------------------------------
SCHEMA = "https://developer.microsoft.com/json-schemas/fabric/item/report/definition"
SCHEMA_VERSIONS_FILE = HERE / "pbir_schema_versions.json"
PAGE_W, PAGE_H = 1280, 720
NAVY, INK, INK2 = "#17375E", "#1D1D1B", "#52514E"
F = "fact_seismic_event"


def col(entity, prop):
    return {"Column": {"Expression": {"SourceRef": {"Entity": entity}}, "Property": prop}}


def meas(entity, prop):
    return {"Measure": {"Expression": {"SourceRef": {"Entity": entity}}, "Property": prop}}


def proj(field):
    kind = "Column" if "Column" in field else "Measure"
    ent = field[kind]["Expression"]["SourceRef"]["Entity"]
    prop = field[kind]["Property"]
    return {"field": field, "queryRef": f"{ent}.{prop}", "nativeQueryRef": prop}


def lit(v):
    return {"expr": {"Literal": {"Value": v}}}


def title_objs(text):
    return {"title": [{"properties": {"show": lit("true"), "text": lit(f"'{text}'"),
                                       "fontColor": {"solid": {"color": lit(f"'{NAVY}'")}},
                                       "bold": lit("true")}}]}


class Page:
    def __init__(self, name, display):
        self.name, self.display, self.visuals = name, display, []

    def _pos(self, x, y, w, h):
        z = 1000 * (len(self.visuals) + 1)
        return {"x": x, "y": y, "z": z, "height": h, "width": w, "tabOrder": z}

    def add(self, vid, vtype, x, y, w, h, query, title=None, sort=None, objects=None):
        visual = {"visualType": vtype,
                  "query": {"queryState": {role: {"projections": [proj(f) for f in fields]}
                                           for role, fields in query.items()}}}
        if sort:
            field, direction = sort
            visual["query"]["sortDefinition"] = {"sort": [{"field": field, "direction": direction}],
                                                 "isDefaultSort": False}
        if vtype == "card":                       # big value, no repeated category label under it
            objects = {"labels": [{"properties": {"fontSize": lit("22D")}}],
                       "categoryLabels": [{"properties": {"show": lit("false")}}], **(objects or {})}
        if vtype == "slicer":                     # compact dropdown slicer
            objects = {"data": [{"properties": {"mode": lit("'Dropdown'")}}], **(objects or {})}
        if objects:
            visual["objects"] = objects
        if title:
            visual["visualContainerObjects"] = title_objs(title)
        visual["drillFilterOtherVisuals"] = True
        self.visuals.append({"name": vid, "position": self._pos(x, y, w, h), "visual": visual})

    def text(self, vid, x, y, w, h, paragraphs):
        """paragraphs: list of paragraphs, each a list of (text, size_pt, bold, color) runs."""
        paras = [{"textRuns": [{"value": t, "textStyle": {"fontSize": f"{s}pt", "color": c,
                                                         **({"fontWeight": "bold"} if b else {})}}
                               for t, s, b, c in para]} for para in paragraphs]
        self.visuals.append({"name": vid, "position": self._pos(x, y, w, h),
                             "visual": {"visualType": "textbox",
                                        "objects": {"general": [{"properties": {"paragraphs": paras}}]},
                                        "drillFilterOtherVisuals": True}})


def header(page, title, subtitle):
    page.text("hdr", 20, 6, 1000, 66, [[(title, 20, True, NAVY)], [(subtitle, 10, False, INK2)]])


def build_pages():
    decisions = json.loads(DECISIONS_FILE.read_text(encoding="utf-8"))

    p1 = Page("p1executive", "Executive Overview")
    header(p1, "Seismo DW - Executive Overview",
           "Global seismic activity M2.5+ (USGS), Jan 2024 - Nov 2026.  Revenue = energy released, "
           "orders = events, customers = affected locations.")
    p1.add("slYear", "slicer", 1040, 6, 220, 66, {"Values": [col("dim_date", "year")]}, title="Year")
    kpis = [("kpiEnergy", "Energy Released (kt TNT)", "Revenue KPI: energy released (kt TNT)"),
            ("kpiEvents", "Total Events", "Orders KPI: seismic events"),
            ("kpiLocations", "Affected Locations", "Customers KPI: affected locations"),
            ("kpiStrong", "Strong Events (M5+)", "Strong events (M5+)")]
    for i, (vid, m, t) in enumerate(kpis):
        p1.add(vid, "card", 20 + i * 312, 80, 300, 118, {"Values": [meas(F, m)]}, title=t)
    p1.add("kpiAvgMag", "card", 20, 206, 300, 104, {"Values": [meas(F, "Avg Magnitude")]}, title="Average magnitude")
    p1.add("kpiMaxMag", "card", 332, 206, 300, 104, {"Values": [meas(F, "Max Magnitude")]}, title="Largest magnitude")
    p1.add("kpiYoY", "card", 644, 206, 300, 104, {"Values": [meas(F, "Events YoY % (same period)")]},
           title="Events vs same period last year")
    p1.add("kpiStrongYoY", "card", 956, 206, 304, 104, {"Values": [meas(F, "Strong Events YoY % (same period)")]},
           title="M5+ events vs same period last year")
    p1.add("trendEvents", "lineChart", 20, 320, 620, 390,
           {"Category": [col("dim_date", "year_month")], "Y": [meas(F, "Total Events")]},
           title="Sales trend: events per month")
    p1.add("trendEnergy", "clusteredColumnChart", 652, 320, 608, 390,
           {"Category": [col("dim_date", "year_month")], "Y": [meas(F, "Energy Released (kt TNT)")]},
           title="Revenue trend: energy released per month (kt TNT)")

    p2 = Page("p2detail", "Detailed Analysis")
    header(p2, "Detailed Analysis",
           "Product = magnitude class, category = event type, region = location type, "
           "customer segment = RFM activity segment of a location.")
    p2.add("slYear2", "slicer", 1040, 6, 220, 66, {"Values": [col("dim_date", "year")]}, title="Year")
    p2.add("prodEvents", "clusteredColumnChart", 20, 80, 410, 300,
           {"Category": [col("dim_magnitude_class", "magnitude_class")], "Y": [meas(F, "Total Events")]},
           title="Product analysis: events by magnitude class")
    p2.add("prodEnergy", "clusteredColumnChart", 440, 80, 410, 300,
           {"Category": [col("dim_magnitude_class", "magnitude_class")], "Y": [meas(F, "Energy Released (kt TNT)")]},
           title="Product analysis: energy by magnitude class (kt TNT)")
    p2.add("regionType", "clusteredBarChart", 860, 80, 400, 300,
           {"Category": [col("dim_location", "location_type")], "Y": [meas(F, "Total Events")]},
           title="Regional analysis: events by region type", sort=(meas(F, "Total Events"), "Descending"))
    p2.add("regionTable", "tableEx", 20, 390, 410, 320,
           {"Values": [col("dim_location", "location_label"), meas(F, "Total Events"),
                       meas(F, "Strong Events (M5+)")]},
           title="Regional analysis: locations ranked by events", sort=(meas(F, "Total Events"), "Descending"))
    p2.add("segChart", "clusteredBarChart", 440, 390, 410, 320,
           {"Category": [col("vw_customer_analysis", "activity_segment")],
            "Y": [meas("vw_customer_analysis", "Segment Locations")]},
           title="Customer segmentation: locations per activity segment")
    p2.add("segTable", "tableEx", 860, 390, 400, 320,
           {"Values": [col("vw_customer_analysis", "location_label"), col("vw_customer_analysis", "activity_segment"),
                       col("vw_customer_analysis", "events")]},
           title="Customer segmentation: location detail",
           sort=(col("vw_customer_analysis", "events"), "Descending"))

    p3 = Page("p3decision", "Decision Page")
    header(p3, "Decision Page", "Based on the dashboard, what decision should management take?")
    p3.text("decisionMain", 20, 76, 1240, 78,
            [[("Recommended decision: ", 15, True, NAVY), (decisions[0]["decision"], 15, True, INK)],
             [("Why: " + decisions[0]["evidence"], 11, False, INK2)]])
    paras = []
    for d in decisions[1:]:
        paras.append([(f"{d['priority']}. {d['decision']}", 11, True, NAVY)])
        paras.append([(d["evidence"], 9, False, INK2)])
    p3.text("decList", 20, 160, 620, 300, [[("Supporting decisions", 12, True, NAVY)]] + paras)
    p3.add("decGrowth", "clusteredColumnChart", 652, 160, 608, 300,
           {"Category": [col("vw_strong_event_growth", "location_label")],
            "Y": [meas("vw_strong_event_growth", "Strong M5+ last year (same period)"),
                  meas("vw_strong_event_growth", "Strong M5+ this year (to date)")]},
           title="Evidence: strong (M5+) events, same calendar period, last year vs this year",
           sort=(meas("vw_strong_event_growth", "Strong M5+ this year (to date)"), "Descending"))
    p3.add("decShare", "card", 20, 470, 300, 110, {"Values": [meas(F, "Strong Event Share")]},
           title="Share of events that are M5+")
    p3.add("decStrongYoY", "card", 20, 590, 300, 120, {"Values": [meas(F, "Strong Events YoY % (same period)")]},
           title="M5+ events vs same period last year")
    p3.add("decClassEnergy", "clusteredColumnChart", 332, 470, 450, 240,
           {"Category": [col("dim_magnitude_class", "magnitude_class")], "Y": [meas(F, "Energy Released (kt TNT)")]},
           title="Where the energy comes from (kt TNT)")
    p3.add("decRegionYear", "clusteredColumnChart", 794, 470, 466, 240,
           {"Category": [col("dim_location", "location_type")], "Series": [col("dim_date", "year")],
            "Y": [meas(F, "Total Events")]},
           title="Events by region type and year")
    return [p1, p2, p3]


def write_report() -> None:
    d = REPORT / "definition"
    if (d / "pages").exists():
        shutil.rmtree(d / "pages")
    v = json.loads(SCHEMA_VERSIONS_FILE.read_text(encoding="utf-8"))
    pages = build_pages()
    (d / "pages").mkdir(parents=True)
    (d / "pages" / "pages.json").write_text(json.dumps({
        "$schema": f"{SCHEMA}/pagesMetadata/{v['pagesMetadata']}/schema.json",
        "pageOrder": [p.name for p in pages], "activePageName": pages[0].name}, indent=2), encoding="utf-8")
    for p in pages:
        pd = d / "pages" / p.name
        (pd / "visuals").mkdir(parents=True)
        (pd / "page.json").write_text(json.dumps({
            "$schema": f"{SCHEMA}/page/{v['page']}/schema.json",
            "name": p.name, "displayName": p.display, "displayOption": "FitToPage",
            "height": PAGE_H, "width": PAGE_W}, indent=2), encoding="utf-8")
        for vis in p.visuals:
            (pd / "visuals" / vis["name"]).mkdir()
            body = {"$schema": f"{SCHEMA}/visualContainer/{v['visualContainer']}/schema.json", **vis}
            (pd / "visuals" / vis["name"] / "visual.json").write_text(json.dumps(body, indent=2), encoding="utf-8")
    print(f"report written: {len(pages)} pages, {sum(len(p.visuals) for p in pages)} visuals")


if __name__ == "__main__":
    write_model()
    if (REPORT / "definition" / "report.json").exists():
        write_report()
    else:
        print("report skeleton missing: save a blank report as PBIP from Power BI Desktop first")
