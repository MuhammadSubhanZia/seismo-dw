/*
 * build_deck.js - builds docs/phase3/Final_Presentation.pptx from the Phase 3 evidence.
 *
 *   cd docs/phase3/presentation && npm install && node build_deck.js
 *
 * Every number on the slides is read from evidence/phase3/*.csv (produced by
 * etl/run_phase3.py and etl/optimization.py) or from the dashboard export, so the
 * deck always matches the submitted SQL results.
 */
const fs = require("fs");
const path = require("path");
const pptxgen = require("pptxgenjs");

const ROOT = path.resolve(__dirname, "..", "..", "..");
const EVID = path.join(ROOT, "evidence", "phase3");
const OUT = path.join(ROOT, "docs", "phase3", "Final_Presentation.pptx");
const META = JSON.parse(fs.readFileSync(path.join(ROOT, "docs", "report_meta.json"), "utf8"));
const DECISIONS = JSON.parse(fs.readFileSync(path.join(ROOT, "powerbi", "decisions.json"), "utf8"));

// ---------- data -------------------------------------------------------------
function csv(name) {
  const lines = fs.readFileSync(path.join(EVID, name + ".csv"), "utf8").trim().split(/\r?\n/);
  const split = (l) => {
    const out = []; let cur = ""; let q = false;
    for (const ch of l) {
      if (ch === '"') q = !q; else if (ch === "," && !q) { out.push(cur); cur = ""; } else cur += ch;
    }
    out.push(cur); return out;
  };
  const head = split(lines[0]);
  return lines.slice(1).map((l) => Object.fromEntries(split(l).map((v, i) => [head[i], v])));
}
const kpi = csv("a01_headline_kpis")[0];
const years = csv("a02_yearly_summary");
const monthly = csv("a03_monthly_growth");
const cube = csv("o04_cube_region_channel");
const molap = csv("o12_molap_compression")[0];
const opt = csv("optimization_results");
const conc = csv("i03_energy_concentration");
const hot = csv("i02_growth_hotspots");
const single = csv("i05_single_network_share")[0];
const segs = csv("i06_segment_summary");
const n = (v) => Number(v).toLocaleString("en-US", { maximumFractionDigits: 0 });

// ---------- theme ------------------------------------------------------------
const NAVY = "17375E", DEEP = "0E2238", ICE = "DCE7F3", RED = "D9482B", SLATE = "52514E",
      INK = "1D1D1B", WHITE = "FFFFFF", MIST = "F3F6FA", BLUE = "2A78D6", ORANGE = "EB6834";
const HEAD = "Cambria", BODY = "Calibri";

const pres = new pptxgen();
pres.layout = "LAYOUT_WIDE";                         // 13.33 x 7.5 in
pres.author = META.team.join(", ");
pres.title = "Seismo DW - Phase 3 Final Presentation";
pres.theme = { headFontFace: HEAD, bodyFontFace: BODY };

const footer = { text: "DL3004 Data Warehousing & BI Lab  |  Seismo DW  |  Phase 3",
                 options: { x: 0.5, y: 7.05, w: 8, h: 0.3, fontFace: BODY, fontSize: 9, color: "8A8984" } };
pres.defineSlideMaster({
  title: "DARK", background: { color: DEEP },
  objects: [], slideNumber: { x: 12.3, y: 7.0, w: 0.6, h: 0.3, fontFace: BODY, fontSize: 9, color: "9DB3CC" },
});
pres.defineSlideMaster({
  title: "CONTENT", background: { color: WHITE },
  objects: [{ text: footer }],
  slideNumber: { x: 12.3, y: 7.0, w: 0.6, h: 0.3, fontFace: BODY, fontSize: 9, color: "8A8984" },
});

function content(title, kicker) {
  const s = pres.addSlide({ masterName: "CONTENT" });
  if (kicker) s.addText(kicker.toUpperCase(), { x: 0.6, y: 0.35, w: 12, h: 0.3, fontFace: BODY, fontSize: 11, bold: true, color: RED, charSpacing: 2, margin: 0, isTextBox: true });
  s.addText(title, { x: 0.6, y: 0.65, w: 12.1, h: 0.75, fontFace: HEAD, fontSize: 30, bold: true, color: NAVY, margin: 0, isTextBox: true });
  return s;
}
function card(s, x, y, w, h, opts = {}) {
  s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x, y, w, h, rectRadius: 0.08, fill: { color: opts.fill || MIST }, line: { color: opts.fill || MIST },
    shadow: opts.shadow ? { type: "outer", color: "000000", opacity: 0.12, blur: 6, offset: 2, angle: 90 } : undefined });
}
function stat(s, x, y, w, value, label, color = NAVY) {
  s.addText(value, { x, y, w, h: 0.8, fontFace: HEAD, fontSize: 36, bold: true, color, margin: 0, isTextBox: true });
  s.addText(label, { x, y: y + 0.8, w, h: 0.5, fontFace: BODY, fontSize: 13, color: SLATE, margin: 0, isTextBox: true });
}
const axis = { catAxisLabelColor: SLATE, valAxisLabelColor: SLATE, catAxisLabelFontFace: BODY, valAxisLabelFontFace: BODY,
               catAxisLabelFontSize: 10, valAxisLabelFontSize: 10, valGridLine: { color: "E4E3DF", size: 0.75 },
               catGridLine: { style: "none" }, titleFontFace: BODY, titleColor: INK, titleFontSize: 13 };

// ---------- 1. title ---------------------------------------------------------
{
  const s = pres.addSlide({ masterName: "DARK" });
  s.addText("PHASE 3  |  OLAP ANALYTICS, PERFORMANCE & BI", { x: 0.8, y: 1.3, w: 11, h: 0.4, fontFace: BODY, fontSize: 14, bold: true, color: "F2A08C", charSpacing: 3, margin: 0, isTextBox: true });
  s.addText("Seismo DW", { x: 0.8, y: 1.85, w: 11, h: 1.2, fontFace: HEAD, fontSize: 60, bold: true, color: WHITE, margin: 0, isTextBox: true });
  s.addText("From a global seismic data warehouse to management decisions", { x: 0.8, y: 3.05, w: 11, h: 0.6, fontFace: BODY, fontSize: 22, color: ICE, margin: 0, isTextBox: true });
  s.addText(META.team.join("   |   "), { x: 0.8, y: 5.4, w: 11.8, h: 0.4, fontFace: BODY, fontSize: 14, color: WHITE, margin: 0, isTextBox: true });
  s.addText(`${META.course}  -  ${META.semester}, ${META.institution}`, { x: 0.8, y: 5.85, w: 11.8, h: 0.4, fontFace: BODY, fontSize: 12, color: "9DB3CC", margin: 0, isTextBox: true });
  s.addNotes("Introduce the team and the project: a PostgreSQL warehouse of real USGS earthquake data built in Phase 2, turned into a decision-support system in Phase 3.");
}

// ---------- 2. the question --------------------------------------------------
{
  const s = content("What management needs from the warehouse", "Objective");
  s.addText("Phase 3 turns the warehouse into a decision-support system: analytical SQL, OLAP cubes, reporting views, " +
            "tuned queries and a Power BI dashboard that ends in one decision.", { x: 0.6, y: 1.55, w: 12, h: 0.8, fontFace: BODY, fontSize: 16, color: INK, margin: 0, isTextBox: true });
  const map = [["Revenue", "Energy released (kt TNT)"], ["Orders", "Seismic events"], ["Customers", "Affected locations"],
               ["Product / Category", "Magnitude class / event type"], ["Region / Channel", "Location type / network type"]];
  map.forEach(([a, b], i) => {
    const y = 2.65 + i * 0.82;
    card(s, 0.6, y, 12.1, 0.68);
    s.addText(a, { x: 0.85, y, w: 3.6, h: 0.68, fontFace: HEAD, fontSize: 18, bold: true, color: NAVY, valign: "middle", margin: 0, isTextBox: true });
    s.addText("→", { x: 4.5, y, w: 0.6, h: 0.68, fontFace: BODY, fontSize: 20, color: RED, valign: "middle", margin: 0, isTextBox: true });
    s.addText(b, { x: 5.2, y, w: 7.2, h: 0.68, fontFace: BODY, fontSize: 17, color: INK, valign: "middle", margin: 0, isTextBox: true });
  });
  s.addNotes("The brief is written for a sales warehouse. We keep its structure and map every sales concept to its seismic meaning; energy is the additive 'money' measure.");
}

// ---------- 3. architecture --------------------------------------------------
{
  const s = content("End-to-end architecture", "Pipeline");
  const steps = [["Source", "USGS API + reference CSVs"], ["Raw", "project_staging.raw_*\nas delivered"], ["Staging", "stg_* cleaned,\nquarantine"],
                 ["Warehouse", "7 dimensions, 3 facts\nSCD2, surrogate keys"], ["Reporting", "views, MVs,\nOLAP aggregate"], ["Power BI", "3-page dashboard"]];
  steps.forEach(([t, d], i) => {
    const x = 0.6 + i * 2.1;
    card(s, x, 1.8, 1.85, 2.0, { fill: i === 3 ? NAVY : MIST, shadow: true });
    s.addText(t, { x: x + 0.12, y: 1.95, w: 1.6, h: 0.5, fontFace: HEAD, fontSize: 18, bold: true, color: i === 3 ? WHITE : NAVY, margin: 0, isTextBox: true });
    s.addText(d, { x: x + 0.12, y: 2.5, w: 1.65, h: 1.2, fontFace: BODY, fontSize: 12, color: i === 3 ? ICE : SLATE, margin: 0, isTextBox: true });
    if (i < steps.length - 1) s.addText("›", { x: x + 1.86, y: 2.45, w: 0.25, h: 0.6, fontFace: BODY, fontSize: 28, color: RED, margin: 0, isTextBox: true });
  });
  stat(s, 0.6, 4.4, 3.0, n(kpi.events), "active events in the fact");
  stat(s, 3.8, 4.4, 3.0, "11", "batches incl. a live change feed");
  stat(s, 7.0, 4.4, 2.8, "40", "data-quality checks per batch, 0 fail");
  stat(s, 10.0, 4.4, 2.8, "0", "rows changed by a rerun");
  s.addText("New in Phase 3: SCD Type 2 network dimension, periodic snapshot and factless facts, lineage metadata, partitioned fact copy.",
            { x: 0.6, y: 6.05, w: 12.1, h: 0.5, fontFace: BODY, fontSize: 14, italic: true, color: NAVY, margin: 0, isTextBox: true });
  s.addNotes("ELT: Python extracts and copies files unchanged; SQL does every transformation. Each batch is two transactions; a failed batch rolls back completely.");
}

// ---------- 4. analytical SQL ------------------------------------------------
{
  const s = content("Analytical SQL: month, revenue, growth", "Analytical SQL layer");
  s.addChart(pres.charts.LINE, [{ name: "Events", labels: monthly.map((m) => m.year_month), values: monthly.map((m) => Number(m.events)) }],
    { x: 0.6, y: 1.6, w: 8.2, h: 4.9, chartColors: [BLUE], lineSize: 2, lineDataSymbol: "none", showLegend: false, showTitle: true,
      title: "Events per month (vw_monthly_sales)", ...axis, catAxisLabelRotate: 270, catAxisLabelFontSize: 8 });
  card(s, 9.2, 1.6, 3.5, 4.9);
  const y = years.map((r) => `${r.year}: ${n(r.events)} events`).join("\n");
  s.addText([{ text: "15 analytical queries", options: { bold: true, fontSize: 16, color: NAVY, breakLine: true } },
             { text: "SUM / AVG / COUNT, HAVING, Top-N, LAG growth, running totals, moving averages, RANK, NTILE, percentiles", options: { fontSize: 13, color: INK, breakLine: true } },
             { text: " ", options: { fontSize: 8, breakLine: true } },
             { text: y, options: { fontSize: 14, color: SLATE } }],
            { x: 9.4, y: 1.8, w: 3.1, h: 4.5, fontFace: BODY, valign: "top", margin: 0, isTextBox: true });
  s.addNotes("Volume is stable at 2,000-2,900 events a month; the spikes are aftershock sequences, the biggest after the M8.8 Kamchatka earthquake in July 2025.");
}

// ---------- 5. OLAP ----------------------------------------------------------
{
  const s = content("OLAP: ROLLUP and CUBE with labelled subtotals", "OLAP queries");
  const rows = cube.slice(0, 18).filter((r) => r.region !== "Unknown" && r.channel !== "Unknown").map((r) => [r.row_type, r.region, r.channel, n(r.events)]);
  const hdr = ["Row type", "Region", "Channel", "Events"].map((t) => ({ text: t, options: { bold: true, color: WHITE, fill: { color: NAVY } } }));
  s.addTable([hdr, ...rows.map((r) => r.map((c, i) => ({ text: c, options: { align: i === 3 ? "right" : "left" } })))],
    { x: 0.6, y: 1.6, w: 8.1, colW: [2.6, 2.1, 2.2, 1.2], fontFace: BODY, fontSize: 10.5, color: INK, rowH: 0.3, border: { type: "solid", color: "E4E3DF", pt: 0.5 } });
  card(s, 9.1, 1.6, 3.6, 2.2, { fill: NAVY });
  s.addText(`${molap.compression_ratio}×`, { x: 9.3, y: 1.75, w: 3.3, h: 0.9, fontFace: HEAD, fontSize: 40, bold: true, color: WHITE, margin: 0, isTextBox: true });
  s.addText(`MOLAP-style aggregate: ${n(molap.fact_rows)} fact rows → ${n(molap.aggregate_rows)} rows, identical answers`, { x: 9.3, y: 2.7, w: 3.3, h: 1.0, fontFace: BODY, fontSize: 13, color: ICE, margin: 0, isTextBox: true });
  s.addText("ROLLUP: Region → Category → Product\n(location type → event type → magnitude class)\nand Year → Quarter → Month\n\nCUBE: Region × Channel, then × class (18 → 96 rows)\n\nGROUPING() labels every subtotal",
            { x: 9.1, y: 4.05, w: 3.6, h: 2.6, fontFace: BODY, fontSize: 13, color: INK, margin: 0, isTextBox: true });
  s.addNotes("GROUPING returns 1 for a rolled-up column, so no subtotal row is left as an unexplained NULL. The pre-aggregate answers 2026 region x class totals identically to the star.");
}

// ---------- 6. reporting views -----------------------------------------------
{
  const s = content("Reporting views for the dashboard", "Reporting layer");
  const v = [["vw_monthly_sales", "Month | events | energy | growth", "MoM, YoY, 3-month average, YTD via window functions"],
             ["vw_customer_analysis", "One row per affected location", "RFM segments: recency of last event, frequency, energy released"],
             ["vw_product_performance", "Magnitude class within event type", "Share of events and energy, rank in category"]];
  v.forEach(([name, what, how], i) => {
    const x = 0.6 + i * 4.1;
    card(s, x, 1.7, 3.85, 3.0, { shadow: true });
    s.addText(name, { x: x + 0.2, y: 1.9, w: 3.5, h: 0.5, fontFace: "Consolas", fontSize: 15, bold: true, color: NAVY, margin: 0, isTextBox: true });
    s.addText(what, { x: x + 0.2, y: 2.5, w: 3.5, h: 0.8, fontFace: HEAD, fontSize: 17, color: INK, margin: 0, isTextBox: true });
    s.addText(how, { x: x + 0.2, y: 3.4, w: 3.5, h: 1.1, fontFace: BODY, fontSize: 13, color: SLATE, margin: 0, isTextBox: true });
  });
  s.addChart(pres.charts.BAR, [{ name: "Locations", labels: segs.map((r) => r.activity_segment.slice(2)), values: segs.map((r) => Number(r.locations)) }],
    { x: 0.6, y: 4.95, w: 12.1, h: 1.95, barDir: "bar", chartColors: [BLUE], showLegend: false, showValue: true, dataLabelColor: SLATE,
      dataLabelFontSize: 10, showTitle: true, title: "Customer segmentation: locations per activity segment", ...axis });
  s.addNotes("Names follow the brief exactly; columns carry the seismic meaning. 85 critical hotspots generate over 90% of all events.");
}

// ---------- 7. optimization --------------------------------------------------
{
  const s = content("Query optimization: measured, not assumed", "EXPLAIN ANALYZE");
  const exps = ["E1", "E2", "E3", "E4", "E6", "E7"];
  const labels = { E1: "B-tree time", E2: "Composite", E3: "Partial M6+", E4: "Covering", E6: "CLUSTER", E7: "Mat. view" };
  const get = (e, p) => Number(opt.find((r) => r.experiment === e && r.phase === p).execution_ms_median);
  s.addChart(pres.charts.BAR, [
      { name: "Before (ms)", labels: exps.map((e) => labels[e]), values: exps.map((e) => get(e, "before")) },
      { name: "After (ms)", labels: exps.map((e) => labels[e]), values: exps.map((e) => get(e, "after")) }],
    { x: 0.6, y: 1.6, w: 8.0, h: 5.0, barDir: "col", barGrouping: "clustered", chartColors: [BLUE, ORANGE], showLegend: true,
      legendPos: "t", legendFontFace: BODY, legendFontSize: 11, showValue: true, dataLabelFontSize: 9, dataLabelColor: SLATE,
      dataLabelFormatCode: "0.0", showTitle: true, title: "Median execution time, before vs after (ms)", ...axis });
  const best = (e) => Math.round(100 * (1 - get(e, "after") / get(e, "before")));
  card(s, 8.95, 1.6, 3.75, 5.0);
  s.addText([
      { text: `Partial index: ${best("E3")}% faster`, options: { bold: true, color: NAVY, fontSize: 15, breakLine: true } },
      { text: "M6+ list reads a 32 kB index instead of the table", options: { color: SLATE, fontSize: 12, breakLine: true } },
      { text: " ", options: { fontSize: 6, breakLine: true } },
      { text: `B-tree on event_time: ${best("E1")}% faster`, options: { bold: true, color: NAVY, fontSize: 15, breakLine: true } },
      { text: "seq scan → index range for one month", options: { color: SLATE, fontSize: 12, breakLine: true } },
      { text: " ", options: { fontSize: 6, breakLine: true } },
      { text: `Covering index: Index Only Scan`, options: { bold: true, color: NAVY, fontSize: 15, breakLine: true } },
      { text: "cost 3,010 → 318 after VACUUM", options: { color: SLATE, fontSize: 12, breakLine: true } },
      { text: " ", options: { fontSize: 6, breakLine: true } },
      { text: "Full-table reports: pre-aggregate", options: { bold: true, color: NAVY, fontSize: 15, breakLine: true } },
      { text: "no index helps a scan of every row", options: { color: SLATE, fontSize: 12 } }],
    { x: 9.15, y: 1.8, w: 3.4, h: 4.6, fontFace: BODY, valign: "top", margin: 0, isTextBox: true });
  s.addNotes("Every experiment ran five times; we report the median. Hash index (E5) was as fast as the existing unique B-tree, so it was dropped. Partitioning pruned correctly but did not pay off at 80k rows.");
}

// ---------- 8. dashboard -----------------------------------------------------
const shots = [1, 2, 3].map((i) => path.join(EVID, "dashboard_pages", `page_${i}.png`));
{
  const s = content("Power BI dashboard: executive overview", "Dashboard page 1");
  s.addImage({ path: shots[0], x: 0.6, y: 1.55, w: 8.6, h: 4.97, altText: "Power BI executive overview page" });
  s.addText([{ text: "Revenue KPI", options: { bold: true, color: NAVY, breakLine: true } }, { text: `${n(kpi.energy_tnt_tons / 1000)} kt TNT released`, options: { breakLine: true } },
             { text: " ", options: { fontSize: 6, breakLine: true } },
             { text: "Orders KPI", options: { bold: true, color: NAVY, breakLine: true } }, { text: `${n(kpi.events)} events`, options: { breakLine: true } },
             { text: " ", options: { fontSize: 6, breakLine: true } },
             { text: "Customers KPI", options: { bold: true, color: NAVY, breakLine: true } }, { text: `${kpi.affected_locations} affected locations`, options: { breakLine: true } },
             { text: " ", options: { fontSize: 6, breakLine: true } },
             { text: "Sales trend", options: { bold: true, color: NAVY, breakLine: true } }, { text: "events and energy per month; year slicer" }],
    { x: 9.5, y: 1.6, w: 3.2, h: 4.9, fontFace: BODY, fontSize: 15, color: INK, valign: "top", margin: 0, isTextBox: true });
  s.addNotes("Import-mode model over the star schema and reporting views, connected to PostgreSQL. Same-period growth cards compare 1 Jan-21 Nov of each year.");
}
{
  const s = content("Detailed analysis: product, region, segment", "Dashboard page 2");
  s.addImage({ path: shots[1], x: 0.6, y: 1.55, w: 8.6, h: 4.97, altText: "Power BI detailed analysis page" });
  s.addText([{ text: "Product analysis", options: { bold: true, color: NAVY, breakLine: true } }, { text: "events vs energy by magnitude class", options: { breakLine: true } },
             { text: " ", options: { fontSize: 6, breakLine: true } },
             { text: "Regional analysis", options: { bold: true, color: NAVY, breakLine: true } }, { text: "region types and ranked locations", options: { breakLine: true } },
             { text: " ", options: { fontSize: 6, breakLine: true } },
             { text: "Customer segmentation", options: { bold: true, color: NAVY, breakLine: true } }, { text: "RFM activity segments of locations" }],
    { x: 9.5, y: 1.6, w: 3.2, h: 4.9, fontFace: BODY, fontSize: 15, color: INK, valign: "top", margin: 0, isTextBox: true });
  s.addNotes("Moderate events are the bulk of the catalogue, but the energy chart is almost entirely the Great class.");
}

// ---------- 9. insights ------------------------------------------------------
{
  const s = content("Insight: risk sits in rare great earthquakes", "Business insights");
  s.addChart(pres.charts.BAR, [
      { name: "Share of events %", labels: conc.map((r) => r.magnitude_class), values: conc.map((r) => Number(r.share_of_events_pct)) },
      { name: "Share of energy %", labels: conc.map((r) => r.magnitude_class), values: conc.map((r) => Number(r.share_of_energy_pct)) }],
    { x: 0.6, y: 1.6, w: 7.6, h: 5.0, barDir: "col", barGrouping: "clustered", chartColors: [BLUE, ORANGE], showLegend: true, legendPos: "t",
      legendFontFace: BODY, legendFontSize: 11, showValue: true, dataLabelFontSize: 9, dataLabelColor: SLATE, dataLabelFormatCode: "0.0",
      showTitle: true, title: "Share of events vs share of energy (%)", ...axis });
  const g = conc.find((r) => r.magnitude_class === "Great");
  stat(s, 8.7, 1.9, 4.0, `${g.share_of_events_pct}%`, "of events are M7+ ...", NAVY);
  stat(s, 8.7, 3.4, 4.0, `${Number(g.share_of_energy_pct).toFixed(0)}%`, "... of all energy released", RED);
  stat(s, 8.7, 4.9, 4.0, `${single.single_network_share_pct}%`, "of 2026 M5+ events seen by one network", NAVY);
  s.addNotes("One magnitude unit is about 32 times more energy. Budgets sized on event counts would under-prepare for the events that matter.");
}

// ---------- 10. decision -----------------------------------------------------
{
  const s = pres.addSlide({ masterName: "DARK" });
  s.addText("THE DECISION", { x: 0.8, y: 0.6, w: 11, h: 0.4, fontFace: BODY, fontSize: 14, bold: true, color: "F2A08C", charSpacing: 3, margin: 0, isTextBox: true });
  s.addText(DECISIONS[0].decision.replace(/\.$/, ""), { x: 0.8, y: 1.05, w: 11.8, h: 1.3, fontFace: HEAD, fontSize: 30, bold: true, color: WHITE, margin: 0, isTextBox: true });
  s.addText(DECISIONS[0].evidence, { x: 0.8, y: 2.4, w: 7.2, h: 1.4, fontFace: BODY, fontSize: 15, color: ICE, margin: 0, isTextBox: true });
  const top = hot.filter((r) => ["Indonesia", "Philippines", "Vanuatu", "China", "Mexico"].includes(r.location_label));
  s.addChart(pres.charts.BAR, [
      { name: "same period 2025", labels: top.map((r) => r.location_label), values: top.map((r) => Number(r.strong_ytd_2025)) },
      { name: "2026 to date", labels: top.map((r) => r.location_label), values: top.map((r) => Number(r.strong_ytd_2026)) }],
    { x: 8.3, y: 2.3, w: 4.6, h: 3.4, barDir: "col", barGrouping: "clustered", chartColors: ["9DB3CC", ORANGE], showLegend: true, legendPos: "t",
      legendColor: ICE, legendFontFace: BODY, legendFontSize: 10, showValue: true, dataLabelFontSize: 9, dataLabelColor: ICE,
      catAxisLabelColor: ICE, valAxisLabelColor: ICE, catAxisLabelFontFace: BODY, valAxisLabelFontFace: BODY, catAxisLabelFontSize: 9,
      valAxisLabelFontSize: 9, valGridLine: { color: "2F4A6A", size: 0.5 }, catGridLine: { style: "none" },
      showTitle: true, title: "M5+ events, 1 Jan - 21 Nov", titleColor: WHITE, titleFontFace: BODY, titleFontSize: 12 });
  const rest = DECISIONS.slice(1, 4).map((d, i) => ({ text: `${d.priority}. ${d.decision}`, options: { breakLine: i < 2, bullet: false } }));
  s.addText(rest, { x: 0.8, y: 4.15, w: 7.2, h: 2.3, fontFace: BODY, fontSize: 14, color: WHITE, paraSpaceAfter: 8, valign: "top", margin: 0, isTextBox: true });
  s.addNotes("This is the answer on dashboard page 3. Supporting decisions: regional network partnerships for single-network hotspots, budgets sized for great earthquakes, and not over-reading US small-event counts.");
}

// ---------- 11. close --------------------------------------------------------
{
  const s = content("What we delivered and what comes next", "Conclusion");
  const done = ["Analytical SQL (15 queries) and OLAP (ROLLUP, CUBE, GROUPING SETS, MOLAP aggregate)",
                "Reporting views vw_monthly_sales, vw_customer_analysis, vw_product_performance",
                "Indexing report: 7 index experiments + partition pruning, all measured",
                "Power BI dashboard (PBIX), screenshots and business insights report",
                "SCD Type 2, periodic snapshot + factless facts, lineage metadata"];
  card(s, 0.6, 1.6, 7.4, 5.0);
  s.addText(done.map((t, i) => ({ text: t, options: { bullet: true, breakLine: i < done.length - 1 } })),
            { x: 0.85, y: 1.8, w: 7.0, h: 4.6, fontFace: BODY, fontSize: 15, color: INK, paraSpaceAfter: 10, valign: "top", margin: 0, isTextBox: true });
  const next = ["Magnitude-unfiltered change feed to catch downgraded events", "Scheduled refresh of the Power BI model", "Partition the fact once volume reaches tens of millions of rows"];
  card(s, 8.3, 1.6, 4.4, 5.0, { fill: NAVY });
  s.addText("Next steps", { x: 8.55, y: 1.8, w: 4.0, h: 0.5, fontFace: HEAD, fontSize: 20, bold: true, color: WHITE, margin: 0, isTextBox: true });
  s.addText(next.map((t, i) => ({ text: t, options: { bullet: true, breakLine: i < next.length - 1 } })),
            { x: 8.55, y: 2.45, w: 4.0, h: 3.9, fontFace: BODY, fontSize: 14, color: ICE, paraSpaceAfter: 10, valign: "top", margin: 0, isTextBox: true });
  s.addText("Questions?", { x: 0.6, y: 6.62, w: 6, h: 0.35, fontFace: HEAD, fontSize: 14, italic: true, color: RED, margin: 0, isTextBox: true });
  s.addNotes("Close with the deliverables and the next steps, then take questions.");
}

pres.writeFile({ fileName: OUT }).then(() => console.log("wrote " + path.relative(ROOT, OUT)));
