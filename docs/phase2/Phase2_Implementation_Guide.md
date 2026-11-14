# Phase 2 — Physical Data Warehouse Implementation & ETL Pipeline

This guide maps every requirement of the Phase 2 brief (and the aligned Labs 06 and 07) to the file
and object that implements it, then documents the source-to-target mapping and the main design decisions.

## 1. Requirement map

| Phase 2 brief | Implementation | Evidence |
|---|---|---|
| **1. Data source**: public dataset (Option A), ≥100 dimension records, ≥10,000 fact records | USGS FDSN Event Web Service (government open data), extracted by `etl/extract_usgs.py` into `data/source/*.geojson.gz`; 4 reference CSVs | 79,975 fact rows; `dim_location` 299 rows, `dim_date` 1,096 rows (`evidence/05_table_row_counts.csv`) |
| **2. Architecture**: Source files → Staging → Warehouse → Reporting; schemas `project_staging`, `project_dw`, `project_reporting` | `sql/01_create_schemas.sql`; README architecture diagram | all objects live in those three schemas |
| **3. Staging layer**: staging tables; remove duplicates, handle NULLs, standardise text, convert types | `sql/staging/02_staging_schema.sql` (raw_* + stg_* tables), `11_clean_reference_to_staging.sql`, `12_clean_events_to_staging.sql` | Data Cleaning Report; `rejected_event` |
| **4. Dimensions with surrogate keys** (business key retained) | `sql/dw/03_dw_schema.sql`; loads in `sql/dimensions/20_`–`26_` | e.g. `location_code 'UNITED_STATES:CALIFORNIA' → location_key 1226`; `evidence/10_dimension_samples.csv` |
| **5. Fact loading via business key → surrogate key** | `sql/facts/30_load_fact_seismic_event.sql` | `evidence/06_surrogate_key_mapping_trace.csv` |
| **6. Data quality**: completeness, accuracy (revenue reconciliation), integrity (FK validation, orphan facts = 0) | `sql/quality/40_data_quality_checks.sql` (40 checks stored in `dq_check_result`), `41_validation_and_analysis.sql` | Data Quality Report; `evidence/04_data_quality_results.csv` |

| Marking rubric | Where it is earned |
|---|---|
| Database Implementation (10) | 3 schemas, 23 tables, 5 views + 1 materialized view, PK/FK/UNIQUE/CHECK constraints, FK indexes, materialized reporting view, idempotent DDL |
| ETL Pipeline (15) | Python extract + COPY loader, SQL ELT transformations, batch control, 2-transaction batches with rollback, file-hash rerun guard, incremental batches, watermark, quarantine, idempotent rerun |
| Surrogate Key Implementation (5) | identity keys from 1001, UNIQUE business keys, Unknown (-1) and inferred members, smart `date_key`, fact stores surrogate keys only, unmapped keys rejected not hidden |
| Data Quality Validation (10) | 40 automated checks per batch (completeness, accuracy, validity, integrity, uniqueness, consistency), reconciliation of counts and measures, raw-to-fact value check, constraint test, broken-load simulation |

| Lab 06 task | Implementation |
|---|---|
| 3.1 separate staging and DW schemas | `project_staging`, `project_dw` (+ `project_reporting`) |
| 4.1–4.3 staging tables, import, profiling | `raw_*` tables (all TEXT/JSONB, no surrogate keys), COPY loader, `10_profile_raw_data.sql` |
| 5.1–5.3 dimensions, standardise while loading, uniqueness | `20_`–`26_`, U01–U07 checks |
| 6.1–6.3 date dimension via `generate_series`, coverage | `20_load_dim_date.sql` (2024-01-01 … 2026-12-31), K03 |
| 7.1–7.3 fact table, surrogate mapping, mapping explanation | `30_load_fact_seismic_event.sql`, `mapping_trace` query |
| 8.1–8.4 orphan checks, grain and measure reconciliation, constraint test | I01–I07, A01–A05, `grain_reconciliation`, `evidence/11_constraint_test.txt` |
| 9.1–9.3 analytical validation, source vs warehouse | `41_validation_and_analysis.sql` (`analysis_*`, `source_vs_warehouse`) |
| 10–11 debugging challenge, broken load simulation | `duplicate_key_diagnostic`, `broken_load_simulation` |

| Lab 07 task | Implementation |
|---|---|
| 1 schemas + ingestion audit table (batch id, source, counts, status) | `etl_batch` (+ `etl_step_log`) |
| 2 profile and stage, deterministic dedupe, traceable source id | `12_clean_events_to_staging.sql`; every stg row keeps `raw_id` and `batch_id` |
| 3 dimensions before facts, unique load key, reject unmapped keys | `EVENT_BATCH_SCRIPTS` order in `etl/config.py`; `UNIQUE (event_id)`; `UNMAPPED_*` rejects |
| 4 rejected rows with reason, batch and time | `rejected_event` (stage, reason_code, reason_detail, batch_id, rejected_at) |
| 5 Python ETL with parameterised loads | `etl/load_raw.py` (COPY, no SQL string building from file values) |
| 6 incremental load, watermark, safe rerun | full 2024–25 batch, incremental 2026 batch, `etl_watermark`, `rerun-demo` |
| 7 reconcile and report | DQ checks A01–A06, `batch_reconciliation`, `rejected_by_reason` |

## 2. Physical objects

| Schema | Object | Purpose |
|---|---|---|
| project_staging | `etl_batch`, `etl_step_log`, `etl_watermark` | ETL control and audit |
| | `raw_usgs_event`, `raw_seismic_network`, `raw_magnitude_type`, `raw_us_state`, `raw_country_alias` | landing tables, rows exactly as delivered |
| | `v_raw_usgs_event_flat` | all-TEXT projection of the raw JSON for profiling |
| | `stg_seismic_event`, `stg_seismic_network`, `stg_magnitude_type`, `stg_us_state`, `stg_country_alias` | cleaned staging tables |
| | `rejected_event`, `dq_check_result` | quarantine and data-quality results |
| project_dw | `dim_date`, `dim_location`, `dim_network`, `dim_magnitude_type`, `dim_event_type`, `dim_magnitude_class`, `dim_depth_class` | dimensions |
| | `fact_seismic_event` | fact table (grain: one USGS event) |
| project_reporting | `vw_seismic_event_detail`, `mv_daily_location_activity`, `vw_monthly_activity`, `vw_etl_batch_summary`, `vw_dq_latest_run` | reporting / BI layer |

## 3. Source-to-target mapping (`fact_seismic_event`)

| Source (GeoJSON) | Staging (`stg_seismic_event`) | Transformation | Warehouse |
|---|---|---|---|
| `id` | `event_id` | trim; NULL → reject | `event_id` (UNIQUE, degenerate) |
| `properties.ids` | `associated_ids TEXT[]` | split list | used to reject merged alias ids |
| `properties.time` (epoch ms) | `event_time TIMESTAMPTZ` | `to_timestamp(ms/1000)`; NULL → reject | `event_time`, `event_hour_utc`, `date_key` → `dim_date` |
| `properties.updated` | `source_updated_at` | epoch → timestamptz | `source_updated_at` (upsert version guard) |
| `properties.mag` | `magnitude NUMERIC(4,2)` | safe cast, round 2; range [-2,10] | `magnitude`; `magnitude_class_key` (range join); `energy_joules = 10^(1.5M+4.8)` |
| `properties.magType` | `magnitude_type` | trim, lower | `magnitude_type_key` → `dim_magnitude_type` (NULL → -1) |
| `geometry.coordinates[2]` | `depth_km NUMERIC(8,3)` | safe cast; range [-10,800] | `depth_km`; `depth_class_key` (range join) |
| `geometry.coordinates[1]`, `[0]` | `latitude`, `longitude` | safe cast; range check | `latitude`, `longitude` |
| `properties.place` | `place`, `nearest_place`, `country`, `state_province`, `location_code` | trim; conform area token via ref US states + country aliases | `place`, `nearest_place`; `location_key` → `dim_location` |
| `properties.net` | `network_code` | trim, lower | `network_key` → `dim_network` (inferred member if not in reference) |
| `properties.type` | `event_type` | trim, lower | `event_type_key` → `dim_event_type` |
| `properties.status` | `review_status`, `is_active` | lower; NULL → 'unknown'; deleted → inactive | `review_status`, `is_active` (soft delete) |
| `properties.alert` | `alert_level` | lower; NULL → 'none' | `alert_level` |
| `properties.tsunami` | `tsunami_flag` | `= 1`; NULL → FALSE | `tsunami_flag` |
| `properties.felt` | `felt_reports` | NULL → 0 | `felt_reports` |
| `properties.cdi`, `mmi` | `cdi`, `mmi` | safe cast; NULL kept | `cdi`, `mmi` |
| `properties.sig` | `significance` | NULL → 0 | `significance`, `is_significant (>= 600)` |
| `properties.nst`, `gap`, `rms`, `dmin` | `station_count`, `azimuthal_gap`, `rms_residual`, `min_distance_deg` | safe cast; NULL kept | same names |

## 4. Design decisions

| Decision | Choice | Reason |
|---|---|---|
| ETL vs ELT | ELT: Python lands files unchanged, SQL transforms in PostgreSQL | raw rows stay available for audit and reprocessing; transformations are set-based, versioned SQL; matches Lab 07 |
| Raw storage of GeoJSON | `JSONB` per feature + md5 hash | preserves every source field (schema drift safe); hash detects identical vs changed versions |
| Batch processing | one batch per source file, 2 transactions, SHA-256 rerun guard | atomic loads; failed batches leave no partial warehouse and can be reprocessed |
| Fact grain | one row per USGS event, latest version | analysts want the current truth; every version stays in `stg_seismic_event` |
| Idempotency | `UNIQUE(event_id)` + upsert that accepts only a newer `updated` timestamp | a date watermark alone is not idempotent (Lab 07 Task 6); identical/older copies change nothing |
| Late-arriving data | batches are processed by batch id, not by an event-date watermark | an old snapshot (Dec 2024) loaded after 2026 data is still evaluated, not skipped |
| Merged USGS ids | reject alias ids listed in another event's `ids`; deactivate an alias if its preferred event arrives later | without it, the same earthquake is counted twice while every key-based check still passes |
| Surrogate keys | identity from 1001, `date_key = YYYYMMDD` | compact integer joins; stable if a source code changes; Phase 2 example `customer_key = 1001` |
| Unknown vs unmapped | NULL attribute → Unknown member -1; non-NULL code without a dimension row → rejected | -1 must never hide a mapping defect (Lab 07 Task 3) |
| Codes missing from reference CSVs | inferred dimension member (`is_inferred = TRUE`) | real USGS codes (e.g. network `ew`) are valid even if our reference file lags |
| Soft deletes | USGS `status = deleted` → `is_active = FALSE` | keeps history; reporting views filter on `is_active` |
| Energy as the reconciled "revenue" measure | `SUM(energy_joules)` reconciled with relative tolerance 1e-9 | energy is the additive money-like measure of seismic data; floating-point summation order needs a tolerance |
| Negative depths | allowed down to -10 km | USGS reports events above the reference datum with negative depth |

## 5. Incremental loading and reruns

| Batch | File | Type | Outcome |
|---|---|---|---|
| 1–4 | reference CSVs | REFERENCE | staged into `stg_*` |
| 5 | `usgs_events_2024_2025_full.geojson.gz` | FULL_LOAD | 54,438 inserted, 1 rejected (merged alias in the USGS feed itself) |
| 6 | `usgs_events_2026_incremental.geojson.gz` | INCREMENTAL | 25,533 inserted |
| 7 | `usgs_events_2026-09-26_change_feed.geojson.gz` | INCREMENTAL (older snapshot) | 4 inserted, 862 unchanged (older versions), 64 superseded ids + 1 deletion + 1 malformed row rejected |
| 8 | `usgs_events_2024-12_snapshot.geojson.gz` | INCREMENTAL (late-arriving) | 0 inserted, 2,593 unchanged |
| 9 | `usgs_events_2026_incremental.geojson.gz` again | RERUN | 0 inserted, 0 updated; row count and all totals identical |

The watermark (`etl_watermark`) records the newest event time and newest USGS `updated` timestamp loaded.
For the next live increment, `etl/extract_usgs.py --updated-after <max_source_updated_at>` pulls only changed events.
