"""
config.py - connection settings, paths and the source-file manifest.

Connection settings come from environment variables (or a local .env file, see
.env.example). Nothing secret is stored in the repository.
"""
from __future__ import annotations

import os
from pathlib import Path

import psycopg

ROOT = Path(__file__).resolve().parents[1]
SQL_DIR = ROOT / "sql"
SOURCE_DIR = ROOT / "data" / "source"
EVIDENCE_DIR = ROOT / "evidence"


def _load_dotenv() -> None:
    """Minimal .env reader (KEY=VALUE lines) so no extra package is needed."""
    env_file = ROOT / ".env"
    if not env_file.exists():
        return
    for line in env_file.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            os.environ.setdefault(key.strip(), value.strip())


_load_dotenv()

DB_NAME = os.environ.get("PGDATABASE", "seismo_dw")


def connect(dbname: str | None = None, autocommit: bool = False) -> psycopg.Connection:
    """Open a connection. Host/port/user/password follow the standard libpq PG* variables."""
    return psycopg.connect(
        host=os.environ.get("PGHOST", "localhost"),
        port=int(os.environ.get("PGPORT", "5432")),
        user=os.environ.get("PGUSER", "postgres"),
        password=os.environ.get("PGPASSWORD") or None,
        dbname=dbname or DB_NAME,
        autocommit=autocommit,
    )


# ---------------------------------------------------------------------------
# DDL scripts executed by `run_pipeline init` (in this order)
# ---------------------------------------------------------------------------
DDL_SCRIPTS = [
    "01_create_schemas.sql",
    "staging/02_staging_schema.sql",
    "dw/03_dw_schema.sql",
    "reporting/04_reporting_schema.sql",
]

# Transformation scripts executed for every USGS events batch (dimensions BEFORE facts)
EVENT_BATCH_SCRIPTS = [
    "staging/12_clean_events_to_staging.sql",
    "dimensions/20_load_dim_date.sql",
    "dimensions/21_load_dim_magnitude_class.sql",
    "dimensions/22_load_dim_depth_class.sql",
    "dimensions/23_load_dim_event_type.sql",
    "dimensions/24_load_dim_magnitude_type.sql",
    "dimensions/25_load_dim_network.sql",
    "dimensions/26_load_dim_location.sql",
    "facts/30_load_fact_seismic_event.sql",
]
REFERENCE_BATCH_SCRIPTS = ["staging/11_clean_reference_to_staging.sql"]
QUALITY_SCRIPT = "quality/40_data_quality_checks.sql"

# ---------------------------------------------------------------------------
# Source files: CSV header -> raw table column mapping (raw columns == CSV headers)
# ---------------------------------------------------------------------------
REFERENCE_SOURCES = {
    "ref_us_states":        ("raw_us_state",        ["state_code", "state_name", "match_by_name"]),
    "ref_country_aliases":  ("raw_country_alias",   ["alias", "country", "note"]),
    "ref_seismic_networks": ("raw_seismic_network", ["network_code", "network_name", "operator", "region_served", "network_type"]),
    "ref_magnitude_types":  ("raw_magnitude_type",  ["magnitude_type_code", "magnitude_type_name", "scale_family", "description"]),
}

# Load order used by `run_pipeline run`. Reference data first, then the event batches.
MANIFEST = [
    ("ref_us_states.csv",                             "REFERENCE"),
    ("ref_country_aliases.csv",                       "REFERENCE"),
    ("ref_seismic_networks.csv",                      "REFERENCE"),
    ("ref_magnitude_types.csv",                       "REFERENCE"),
    # Batch: full historical load 2024-2025 (Lab 07 Task 6 "first batch")
    ("usgs_events_2024_2025_full.geojson.gz",         "FULL_LOAD"),
    # Batch: incremental 2026 year-to-date (Lab 07 Task 6 "second batch")
    ("usgs_events_2026_incremental.geojson.gz",       "INCREMENTAL"),
    # Batch: older change-feed snapshot (taken 2026-09-26 by Seismo, includes a deleted event)
    ("usgs_events_2026-09-26_change_feed.geojson.gz", "INCREMENTAL"),
    # Batch: older December-2024 snapshot (taken by Seismo) overlapping the full load
    ("usgs_events_2024-12_snapshot.geojson.gz",       "INCREMENTAL"),
]


def source_name_for(path: Path) -> str:
    name = path.name
    if name.endswith((".geojson.gz", ".geojson", ".json", ".json.gz")):
        return "usgs_events"
    stem = name.removesuffix(".csv")
    if stem in REFERENCE_SOURCES:
        return stem
    raise ValueError(f"Unknown source file: {name}")
