/* ============================================================================
   06_snapshot_and_factless_facts.sql  -  two extra fact types (Phase 3 extension)

   The sample architecture has a periodic-snapshot fact (inventory) and a factless
   fact (promotions). Their seismic equivalents:

   fact_location_monthly_snapshot   PERIODIC SNAPSHOT
       grain: one row per location per calendar month, INCLUDING months with no
       events (dense), taken at month end. Mixes three kinds of measures:
         additive       events_in_month, energy_joules_in_month, felt_reports_in_month
         semi-additive  cumulative_events_ytd (sum across locations, never across months)
         non-additive   max_magnitude_in_month, days_since_last_event (a state at month end)

   fact_network_location_coverage   FACTLESS FACT
       grain: one row per (network, location, month) in which that network authored
       at least one event solution for that location. No measures: questions are
       answered by COUNT(*) and by anti-joins ("which locations had NO coverage").

   Both are rebuilt from fact_seismic_event by sql/facts/31_ and 32_.
   ============================================================================ */

SET search_path TO project_dw, public;

CREATE TABLE IF NOT EXISTS project_dw.fact_location_monthly_snapshot (
    snapshot_date_key       INT          NOT NULL REFERENCES project_dw.dim_date (date_key),       -- month-end date
    location_key            INT          NOT NULL REFERENCES project_dw.dim_location (location_key),
    events_in_month         INT          NOT NULL,
    energy_joules_in_month  DOUBLE PRECISION NOT NULL,
    felt_reports_in_month   INT          NOT NULL,
    strong_events_in_month  INT          NOT NULL,                                             -- magnitude >= 5
    max_magnitude_in_month  NUMERIC(4,2),                                                      -- NULL when no events
    cumulative_events_ytd   INT          NOT NULL,                                             -- semi-additive
    days_since_last_event   INT,                                                               -- NULL = never active yet
    is_active_month         BOOLEAN      NOT NULL,
    snapshot_taken_at       TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT pk_fact_location_monthly_snapshot PRIMARY KEY (snapshot_date_key, location_key)
);
CREATE INDEX IF NOT EXISTS ix_snapshot_location ON project_dw.fact_location_monthly_snapshot (location_key);
COMMENT ON TABLE project_dw.fact_location_monthly_snapshot IS
    'Periodic snapshot: one row per location per month (dense, month-end). Additive, semi-additive and non-additive measures.';

CREATE TABLE IF NOT EXISTS project_dw.fact_network_location_coverage (
    month_date_key   INT NOT NULL REFERENCES project_dw.dim_date (date_key),            -- first day of the month
    network_key      INT NOT NULL REFERENCES project_dw.dim_network (network_key),
    location_key     INT NOT NULL REFERENCES project_dw.dim_location (location_key),
    CONSTRAINT pk_fact_network_location_coverage PRIMARY KEY (month_date_key, network_key, location_key)
);
CREATE INDEX IF NOT EXISTS ix_coverage_location ON project_dw.fact_network_location_coverage (location_key);
COMMENT ON TABLE project_dw.fact_network_location_coverage IS
    'Factless fact: a network covered (authored an event for) a location in a month. Analysed with COUNT(*) and anti-joins.';
