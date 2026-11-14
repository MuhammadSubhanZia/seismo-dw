/* ============================================================================
   22_load_dim_depth_class.sql  -  DIMENSION LOAD: dim_depth_class

   Static band dimension carried over from the Seismo Gold layer.
   Negative depths (events above the reference datum, valid in USGS data) fall in
   Shallow because its lower bound is open.
   ============================================================================ */

SET search_path TO project_dw, public;

INSERT INTO project_dw.dim_depth_class
       (depth_class_key, depth_class, depth_range, min_depth_km, max_depth_km, description, sort_order)
OVERRIDING SYSTEM VALUE
VALUES (-1, 'Unknown', 'Unknown', NULL, NULL, 'Depth not reported', 99)
ON CONFLICT (depth_class_key) DO NOTHING;

WITH seed (depth_class, depth_range, min_depth_km, max_depth_km, description, sort_order) AS (
    VALUES ('Shallow',      '< 70 km',   NULL::NUMERIC, 70.0::NUMERIC, 'Crustal events; strongest surface shaking', 1),
           ('Intermediate', '70-299 km', 70.0,  300.0, 'Subducting-slab events', 2),
           ('Deep',         '300+ km',   300.0, NULL,  'Deep-focus events; widely felt, rarely damaging', 3)
), up AS (
    INSERT INTO project_dw.dim_depth_class AS t
           (depth_class, depth_range, min_depth_km, max_depth_km, description, sort_order)
    SELECT * FROM seed
    ON CONFLICT (depth_class) DO UPDATE
       SET depth_range = EXCLUDED.depth_range, min_depth_km = EXCLUDED.min_depth_km,
           max_depth_km = EXCLUDED.max_depth_km, description = EXCLUDED.description,
           sort_order = EXCLUDED.sort_order
     WHERE (t.depth_range, t.min_depth_km, t.max_depth_km, t.description, t.sort_order)
           IS DISTINCT FROM (EXCLUDED.depth_range, EXCLUDED.min_depth_km, EXCLUDED.max_depth_km,
                             EXCLUDED.description, EXCLUDED.sort_order)
    RETURNING (xmax = 0) AS inserted
)
INSERT INTO project_staging.etl_step_log (batch_id, step_name, target_table, rows_processed, rows_inserted, rows_updated)
SELECT NULLIF(current_setting('etl.batch_id', true), '')::BIGINT, 'load_dimension', 'project_dw.dim_depth_class',
       (SELECT count(*) FROM seed), count(*) FILTER (WHERE inserted), count(*) FILTER (WHERE NOT inserted)
FROM up;
