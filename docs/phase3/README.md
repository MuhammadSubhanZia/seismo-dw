# Phase 3 - OLAP Analytics, Performance Optimization & BI Dashboard

Objective of the brief: turn the warehouse into a decision-support system.
Aligned labs: Lab 01 (analytical SQL), Lab 04 (OLAP), Labs 09-11 (joins, indexing, partitioning,
materialized views).

## Deliverables

| Phase 3 deliverable | File(s) |
|---|---|
| Analytical SQL Queries (SQL) | [`sql/analytics/50_analytical_queries.sql`](../../sql/analytics/50_analytical_queries.sql), [`sql/analytics/53_business_insights.sql`](../../sql/analytics/53_business_insights.sql) |
| OLAP Queries (SQL) | [`sql/olap/51_olap_queries.sql`](../../sql/olap/51_olap_queries.sql) |
| Reporting Views (SQL) | [`sql/reporting/52_reporting_views.sql`](../../sql/reporting/52_reporting_views.sql) (`vw_monthly_sales`, `vw_customer_analysis`, `vw_product_performance`) |
| Indexing Report (PDF) | [`Indexing_Report.pdf`](Indexing_Report.pdf) - experiments in [`sql/optimization/`](../../sql/optimization) |
| Power BI Dashboard (PBIX) | [`powerbi/SeismoDW.pbix`](../../powerbi/SeismoDW.pbix) (source as a Power BI project: [`powerbi/SeismoDW.pbip`](../../powerbi)) |
| Dashboard Screenshots (PDF) | [`Dashboard_Screenshots.pdf`](Dashboard_Screenshots.pdf) |
| Business Insights Report (PDF) | [`Business_Insights_Report.pdf`](Business_Insights_Report.pdf) |
| Final Presentation (PPT) | [`Final_Presentation.pptx`](Final_Presentation.pptx) (built by [`presentation/build_deck.js`](presentation/build_deck.js)) |

## Requirement map

| Brief | Implementation |
|---|---|
| 1. Aggregations SUM / AVG / COUNT; "Month \| Revenue \| Growth" | `50_analytical_queries.sql` A01-A15; `vw_monthly_sales` (events, energy, MoM / YoY growth, moving average, YTD) |
| 1. OLAP: ROLLUP Region -> Category -> Product with product, category, region and grand totals | `51_olap_queries.sql` O01 (location type -> event type -> magnitude class), O02 geography, O03 Year -> Quarter -> Month, all labelled with `GROUPING()` |
| 1. OLAP: CUBE Region x Channel | O04 (location type x network type), O05/O06 3-D cube, O07 GROUPING SETS, O08-O11 drill-down, O12-O14 MOLAP-style aggregate vs ROLAP |
| 2. Reporting views vw_monthly_sales, vw_customer_analysis, vw_product_performance | `52_reporting_views.sql` (exact names; seismic columns) |
| 3. EXPLAIN ANALYZE before, CREATE INDEX, EXPLAIN ANALYZE after; compare time and cost | `60_indexing_experiments.sql` E1-E7 (B-tree, composite, partial, covering, hash, CLUSTER, materialized view) measured 5x by `etl/optimization.py`; `61_partitioning_experiments.sql` P1-P3 |
| 4. Power BI connected to the warehouse | Import-mode model on PostgreSQL (`project_dw` + `project_reporting`), parameters `PgServer` / `PgDatabase` |
| 4. Page 1 Executive Overview: revenue, orders, customers KPIs, sales trend | energy released (kt TNT), events, affected locations, strong events, same-period growth, monthly trends |
| 4. Page 2 Detailed Analysis: product, regional, customer segmentation | magnitude-class charts, region type + ranked locations, RFM activity segments |
| 4. Page 3 Decision page | recommended decision with evidence chart and four supporting decisions (`powerbi/decisions.json`) |

| Marking | Where |
|---|---|
| Analytical SQL (10) | 15 analytical queries + 8 insight queries, window functions throughout |
| OLAP Implementation (5) | ROLLUP, CUBE, GROUPING SETS, GROUPING labels, drill-down, MOLAP aggregate |
| Dashboard (10) | 3 pages, 28 visuals, star-schema semantic model, DAX measures |
| Business Insights (5) | Business Insights Report + Decision page |

## Sales vocabulary of the brief -> seismic meaning

| Brief | Seismo DW |
|---|---|
| Revenue | energy released (`energy_tnt_tons`, additive) |
| Orders | seismic events |
| Customers | affected locations (`dim_location`) |
| Product / Category | magnitude class / event type |
| Region / Channel | location type / seismic network type |
| Customer segmentation | RFM-style activity segments of locations (recency, frequency, energy) |

## Blocks added from the sample architecture

| Sample block | Seismo DW |
|---|---|
| SCD Type 1 & 2 | `dim_network` is now SCD Type 2 (`sql/dw/05_scd2_dim_network.sql`, `sql/dimensions/25_load_dim_network.sql`), demonstrated with `data/source/ref_seismic_networks_v2.csv` |
| Periodic snapshot fact (inventory) | `fact_location_monthly_snapshot` - dense month x location, additive / semi-additive / non-additive measures |
| Factless fact (promotions) | `fact_network_location_coverage` - network x location x month |
| Warehouse performance: partitioning, indexes, EXPLAIN ANALYZE | `sql/optimization/60_*`, `61_*`, Indexing Report |
| Gold layer / data marts, aggregated & materialized views | `project_reporting` views, `mv_daily_location_activity`, `agg_month_region_class` |
| Analytics & BI: OLAP ROLLUP / CUBE, window functions, Power BI, business decisions | `sql/analytics`, `sql/olap`, `powerbi/`, Decision page |
| Metadata & data lineage | `meta_lineage_edge`, `meta_lineage_snapshot`, `vw_data_lineage` (`sql/dw/07_*`, `sql/quality/42_*`) |
| Late-arriving data, unknown members, audit & reconciliation | already in Phase 2 (inferred members, -1 members, DQ checks), extended with a live change feed |

## Reproduce

```bash
python -m etl.run_pipeline all          # Phase 2 + 3 load: 11 batches incl. SCD2 update and live change feed
python -m etl.run_phase3 all            # analytical / OLAP queries + indexing and partitioning experiments
python -m etl.build_phase3_reports      # Indexing, Business Insights and Dashboard Screenshots PDFs
python powerbi/generate_pbip.py         # regenerate the Power BI project from code
cd docs/phase3/presentation && npm install && node build_deck.js
```

Open `powerbi/SeismoDW.pbip` (or the `.pbix`) in Power BI Desktop and set the `PgServer` parameter to your
PostgreSQL host to refresh the data. Evidence of every run is in [`evidence/phase3/`](../../evidence/phase3).
