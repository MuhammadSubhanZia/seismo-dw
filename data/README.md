# Source files (`data/source/`)

| File | Origin | Rows | Loaded into |
|---|---|---|---|
| `usgs_events_2024_2025_full.geojson.gz` | USGS FDSN Event API, `starttime=2024-01-01&endtime=2026-01-01&minmagnitude=2.5`, extracted 2026-11-14 with `etl/extract_usgs.py` | 54,439 features | `raw_usgs_event` (full load) |
| `usgs_events_2026_incremental.geojson.gz` | USGS API, `starttime=2026-01-01&endtime=2026-11-14&minmagnitude=2.5`, extracted 2026-11-14 | 25,533 | `raw_usgs_event` (incremental) |
| `usgs_events_2026-09-26_change_feed.geojson.gz` | Seismo project sample: `updatedafter=2026-09-26T08:51&includedeleted=true&minmagnitude=2.5` | 932 | `raw_usgs_event` (older snapshot, includes a deleted event) |
| `usgs_events_2024-12_snapshot.geojson.gz` | Seismo project sample: December 2024, M ≥ 2.5, extracted in September 2026 | 2,593 | `raw_usgs_event` (late-arriving snapshot) |
| `ref_seismic_networks.csv` | compiled by the team from USGS ANSS network documentation | 18 | `raw_seismic_network` → `dim_network` |
| `ref_magnitude_types.csv` | compiled from the USGS "Magnitude Types" documentation | 16 | `raw_magnitude_type` → `dim_magnitude_type` |
| `ref_us_states.csv` | US state / territory codes (`match_by_name = N` for Georgia, which USGS writes as the country) | 52 | `raw_us_state` → location conformance |
| `ref_country_aliases.csv` | alternative spellings seen in USGS place strings | 6 | `raw_country_alias` → location conformance |

The GeoJSON files are gzip-compressed FeatureCollections exactly as returned by the API (one `features[]` element per event).
USGS earthquake data is in the public domain.
