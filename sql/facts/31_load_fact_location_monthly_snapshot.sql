/* ============================================================================
   31_load_fact_location_monthly_snapshot.sql  -  PERIODIC SNAPSHOT LOAD

   Rebuilds the dense month x location snapshot from fact_seismic_event (active
   events only). Every location appears in every month from the first loaded
   month to the last, so a month with zero events is a real row with zeros -
   that is what distinguishes a periodic snapshot from a transaction fact.
   Runs inside the batch transaction, so readers never see a half-built table.
   ============================================================================ */

SET search_path TO project_dw, project_staging, public;

TRUNCATE project_dw.fact_location_monthly_snapshot;

WITH months AS (
    SELECT DISTINCT d.year, d.month,
           max(d.date_key) OVER (PARTITION BY d.year, d.month) AS month_end_key,
           max(d.full_date) OVER (PARTITION BY d.year, d.month) AS month_end
    FROM project_dw.dim_date d
    WHERE d.full_date BETWEEN (SELECT date_trunc('month', min(event_time AT TIME ZONE 'UTC'))::DATE FROM project_dw.fact_seismic_event)
                          AND (SELECT max(event_time AT TIME ZONE 'UTC')::DATE FROM project_dw.fact_seismic_event)
), activity AS (
    SELECT d.year, d.month, f.location_key,
           count(*)                                  AS events,
           sum(f.energy_joules)                      AS energy,
           sum(f.felt_reports)                       AS felt,
           count(*) FILTER (WHERE f.magnitude >= 5)  AS strong,
           max(f.magnitude)                          AS max_mag,
           max((f.event_time AT TIME ZONE 'UTC')::DATE) AS last_event_date
    FROM project_dw.fact_seismic_event f
    JOIN project_dw.dim_date d ON d.date_key = f.date_key
    WHERE f.is_active
    GROUP BY d.year, d.month, f.location_key
), grid AS (
    SELECT DISTINCT m.year, m.month, m.month_end_key, m.month_end, l.location_key
    FROM months m CROSS JOIN project_dw.dim_location l
    WHERE l.location_key <> -1
), filled AS (
    SELECT g.*,
           COALESCE(a.events, 0)  AS events,
           COALESCE(a.energy, 0)  AS energy,
           COALESCE(a.felt, 0)    AS felt,
           COALESCE(a.strong, 0)  AS strong,
           a.max_mag,
           -- last event date carried forward to every later month (state at month end)
           max(a.last_event_date) OVER (PARTITION BY g.location_key ORDER BY g.year, g.month
                                        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS last_event_so_far,
           sum(COALESCE(a.events, 0)) OVER (PARTITION BY g.location_key, g.year ORDER BY g.month) AS ytd
    FROM grid g
    LEFT JOIN activity a ON a.year = g.year AND a.month = g.month AND a.location_key = g.location_key
), ins AS (
    INSERT INTO project_dw.fact_location_monthly_snapshot
           (snapshot_date_key, location_key, events_in_month, energy_joules_in_month, felt_reports_in_month,
            strong_events_in_month, max_magnitude_in_month, cumulative_events_ytd, days_since_last_event, is_active_month)
    SELECT month_end_key, location_key, events, energy, felt, strong, max_mag, ytd,
           (month_end - last_event_so_far), events > 0
    FROM filled
    RETURNING 1
)
INSERT INTO project_staging.etl_step_log (batch_id, step_name, target_table, rows_processed, rows_inserted, note)
SELECT NULLIF(current_setting('etl.batch_id', true), '')::BIGINT, 'load_fact', 'project_dw.fact_location_monthly_snapshot',
       (SELECT count(*) FROM project_dw.fact_seismic_event WHERE is_active), (SELECT count(*) FROM ins),
       'periodic snapshot rebuilt (dense month x location)';
