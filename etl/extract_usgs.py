"""
extract_usgs.py - EXTRACT step: USGS FDSN Event API  ->  source file (GeoJSON, gzip)

Adapted from the Seismo project's `src/ingestion/fetch_usgs_data.py` / `00_Fetch_USGS_Data.py`.
The warehouse never reads the API directly: the API response is first frozen into a
source file under data/source/, which is what the staging layer ingests. This keeps every
load reproducible (same file -> same SHA-256 -> same batch result).

Examples
--------
# Full historical load (Batch 1): 2024-01-01 .. 2025-12-31, magnitude >= 2.5
python -m etl.extract_usgs --start 2024-01-01 --end 2026-01-01 \
       --out data/source/usgs_events_2024_2025_full.geojson.gz

# Incremental load (Batch 2): 2026 year-to-date
python -m etl.extract_usgs --start 2026-01-01 --end 2026-11-14 \
       --out data/source/usgs_events_2026_incremental.geojson.gz

# Change feed: everything USGS *updated* after a timestamp, including deleted events
python -m etl.extract_usgs --updated-after 2026-11-01T00:00:00 --include-deleted \
       --out data/source/usgs_updates.geojson.gz
"""
from __future__ import annotations

import argparse
import gzip
import json
import time
from datetime import date, datetime, timezone
from pathlib import Path

import requests

BASE_URL = "https://earthquake.usgs.gov/fdsnws/event/1/query"
API_LIMIT = 20000  # USGS hard limit per request -> we query one month at a time
USER_AGENT = "seismo-dw-academic-etl/1.0"


def month_windows(start: date, end: date):
    """Yield [window_start, window_end) month windows covering [start, end)."""
    cur = start
    while cur < end:
        nxt = date(cur.year + (cur.month == 12), (cur.month % 12) + 1, 1)
        yield cur, min(nxt, end)
        cur = nxt


def fetch(params: dict) -> dict:
    params = {"format": "geojson", "limit": API_LIMIT, "orderby": "time-asc", **params}
    for attempt in range(1, 4):
        try:
            r = requests.get(BASE_URL, params=params, timeout=180, headers={"User-Agent": USER_AGENT})
            r.raise_for_status()
            return r.json()
        except requests.RequestException as exc:  # transient API errors: retry with back-off
            if attempt == 3:
                raise
            print(f"   retry {attempt} after error: {exc}")
            time.sleep(5 * attempt)
    raise RuntimeError("unreachable")


def extract_range(start: date, end: date, min_mag: float) -> list[dict]:
    features: list[dict] = []
    for ws, we in month_windows(start, end):
        data = fetch({"starttime": ws.isoformat(), "endtime": we.isoformat(), "minmagnitude": min_mag})
        n = len(data.get("features", []))
        if n >= API_LIMIT:
            raise RuntimeError(f"{ws}..{we} hit the API limit ({n}); use smaller windows")
        print(f"   {ws} .. {we}: {n:>6,} events")
        features.extend(data["features"])
        time.sleep(1)  # be polite to the public API
    return features


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--start", type=date.fromisoformat, help="event start date (inclusive)")
    ap.add_argument("--end", type=date.fromisoformat, help="event end date (exclusive)")
    ap.add_argument("--updated-after", help="ISO timestamp: fetch events updated after this instant")
    ap.add_argument("--include-deleted", action="store_true", help="include status=deleted events")
    ap.add_argument("--min-mag", type=float, default=2.5)
    ap.add_argument("--out", required=True, type=Path)
    a = ap.parse_args()

    print(f"Extracting USGS events -> {a.out}")
    if a.updated_after:
        params = {"updatedafter": a.updated_after, "minmagnitude": a.min_mag}
        if a.include_deleted:
            params["includedeleted"] = "true"
        features = fetch(params)["features"]
        query = params
    else:
        if not (a.start and a.end):
            ap.error("--start and --end are required unless --updated-after is given")
        features = extract_range(a.start, a.end, a.min_mag)
        query = {"starttime": a.start.isoformat(), "endtime": a.end.isoformat(), "minmagnitude": a.min_mag}

    doc = {
        "type": "FeatureCollection",
        "metadata": {
            "title": "USGS Earthquakes (seismo-dw extract)",
            "api": BASE_URL,
            "query": query,
            "generated": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "count": len(features),
        },
        "features": features,
    }
    a.out.parent.mkdir(parents=True, exist_ok=True)
    opener = gzip.open if a.out.suffix == ".gz" else open
    with opener(a.out, "wt", encoding="utf-8") as fh:
        json.dump(doc, fh, ensure_ascii=False, separators=(",", ":"))
    print(f"Saved {len(features):,} features ({a.out.stat().st_size / 1e6:.1f} MB)")


if __name__ == "__main__":
    main()
