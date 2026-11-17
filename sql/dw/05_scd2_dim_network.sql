/* ============================================================================
   05_scd2_dim_network.sql  -  SCD TYPE 2 for dim_network  (Phase 3 extension)

   Phase 2 kept dim_network as SCD Type 1 (attributes overwritten). A seismic
   network can be renamed or move to another operator, and reports about past
   events should keep the attributes that were valid when those events were
   loaded. This migration turns dim_network into a Type 2 dimension:

       network_key   surrogate key of ONE VERSION of a network
       network_code  business key (no longer unique on its own)
       effective_from / effective_to   validity window of the version
       is_current    TRUE for the single live version of each network_code
       version_no    1, 2, 3 ... per network_code

   Rules (implemented in sql/dimensions/25_load_dim_network.sql):
     - changed reference attributes  -> expire the current row, insert version n+1
     - new network_code              -> insert version 1
     - inferred member later supplied by the reference file -> overwritten in place
       (Type 1 on a placeholder row: it never described a real version)
     - facts are mapped to the CURRENT version at load time, so facts loaded
       before a change keep pointing at the old version (history preserved)

   Idempotent: safe to run more than once.
   ============================================================================ */

SET search_path TO project_dw, public;

ALTER TABLE project_dw.dim_network
    ADD COLUMN IF NOT EXISTS effective_from TIMESTAMPTZ NOT NULL DEFAULT TIMESTAMPTZ '2024-01-01 00:00:00+00',
    ADD COLUMN IF NOT EXISTS effective_to   TIMESTAMPTZ NOT NULL DEFAULT TIMESTAMPTZ '9999-12-31 00:00:00+00',
    ADD COLUMN IF NOT EXISTS is_current     BOOLEAN     NOT NULL DEFAULT TRUE,
    ADD COLUMN IF NOT EXISTS version_no     SMALLINT    NOT NULL DEFAULT 1;

-- the business key is unique per VERSION, and only one current version may exist per code
ALTER TABLE project_dw.dim_network DROP CONSTRAINT IF EXISTS uq_dim_network_code;
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'uq_dim_network_code_version') THEN
        ALTER TABLE project_dw.dim_network
            ADD CONSTRAINT uq_dim_network_code_version UNIQUE (network_code, version_no);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_dim_network_validity') THEN
        ALTER TABLE project_dw.dim_network
            ADD CONSTRAINT ck_dim_network_validity CHECK (effective_from < effective_to);
    END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS ux_dim_network_current
    ON project_dw.dim_network (network_code) WHERE is_current;

COMMENT ON TABLE project_dw.dim_network IS
    'Seismic network that authored the event solution. SCD Type 2 (effective_from/effective_to/is_current), supports inferred members.';
