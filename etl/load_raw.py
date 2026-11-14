"""
load_raw.py - EXTRACT + LOAD into the raw landing tables (project_staging.raw_*).

ELT principle: rows are copied into PostgreSQL exactly as delivered. No trimming,
no type conversion, no de-duplication happens here - that is the job of the SQL
staging scripts, so the raw tables stay useful for audit and reconciliation.

Bulk load uses PostgreSQL COPY (fast, transactional). Each file becomes one batch
in project_staging.etl_batch with its SHA-256, so loading the same file twice is
detected (and skipped unless --force is used).
"""
from __future__ import annotations

import csv
import gzip
import hashlib
import json
from pathlib import Path

import psycopg

from .config import REFERENCE_SOURCES


def file_sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def already_loaded(conn: psycopg.Connection, sha: str) -> int | None:
    """Return the batch_id of a previous successful load of the identical file, if any."""
    row = conn.execute(
        "SELECT max(batch_id) FROM project_staging.etl_batch WHERE file_sha256 = %s AND status = 'LOADED'",
        (sha,),
    ).fetchone()
    return row[0] if row else None


def register_batch(conn: psycopg.Connection, source_name: str, path: Path, load_type: str,
                   sha: str, is_rerun: bool, status: str = "RUNNING", message: str | None = None) -> int:
    row = conn.execute(
        """INSERT INTO project_staging.etl_batch
               (source_name, source_file, file_sha256, load_type, is_rerun, status, error_message)
           VALUES (%s, %s, %s, %s, %s, %s, %s) RETURNING batch_id""",
        (source_name, path.name, sha, load_type, is_rerun, status, message),
    ).fetchone()
    return row[0]


def _read_geojson(path: Path) -> list[dict]:
    opener = gzip.open if path.suffix == ".gz" else open
    with opener(path, "rt", encoding="utf-8") as fh:
        doc = json.load(fh)
    if doc.get("type") != "FeatureCollection" or not isinstance(doc.get("features"), list):
        raise ValueError(f"{path.name} is not a GeoJSON FeatureCollection")
    return doc["features"]


def load_geojson(conn: psycopg.Connection, batch_id: int, path: Path) -> int:
    """One raw row per feature: the untouched JSON plus an md5 used for change detection."""
    features = _read_geojson(path)
    with conn.cursor() as cur:
        with cur.copy(
            "COPY project_staging.raw_usgs_event (batch_id, source_row_num, feature, record_hash) FROM STDIN"
        ) as copy:
            for i, feat in enumerate(features, start=1):
                text = json.dumps(feat, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
                copy.write_row((batch_id, i, text, hashlib.md5(text.encode("utf-8")).hexdigest()))
    return len(features)


def load_csv(conn: psycopg.Connection, batch_id: int, path: Path, source_name: str) -> int:
    """Columns of the raw table equal the CSV headers; values are copied verbatim as TEXT."""
    table, columns = REFERENCE_SOURCES[source_name]
    with open(path, newline="", encoding="utf-8-sig") as fh:
        reader = csv.reader(fh)
        header = next(reader)
        if [h.strip() for h in header] != columns:
            raise ValueError(f"{path.name}: header {header} does not match expected {columns}")
        rows = list(reader)
    cols = ", ".join(["batch_id", "source_row_num", *columns])
    with conn.cursor() as cur:
        with cur.copy(f"COPY project_staging.{table} ({cols}) FROM STDIN") as copy:
            for i, row in enumerate(rows, start=1):
                row = (row + [None] * len(columns))[: len(columns)]   # ragged lines -> NULL padding
                copy.write_row((batch_id, i, *row))
    return len(rows)
