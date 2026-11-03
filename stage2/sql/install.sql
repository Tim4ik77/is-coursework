\set ON_ERROR_STOP on
BEGIN;
\ir 01_schema.sql
\ir 02_integrity.sql
\ir 03_routines.sql
\ir 04_indexes.sql
COMMIT;
