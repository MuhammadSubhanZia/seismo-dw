/* ============================================================================
   00_create_database.sql
   Seismo DW - creates the PostgreSQL database that holds all three layers.

   Run ONCE while connected to the default "postgres" database
   (pgAdmin: Query Tool on "postgres", or:  psql -U postgres -f sql/00_create_database.sql)
   `python -m etl.run_pipeline init` does the same thing automatically.
   ============================================================================ */

CREATE DATABASE seismo_dw
    WITH ENCODING = 'UTF8'
         TEMPLATE = template0;

COMMENT ON DATABASE seismo_dw IS
    'DL3004 Phase 2 - Seismo seismic-event data warehouse (staging -> dw -> reporting)';
