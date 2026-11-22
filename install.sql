\set ON_ERROR_STOP on

BEGIN;
CREATE SCHEMA doom;
\ir engine/world/world.sql
\ir engine/wad/directory.sql
COMMIT;
