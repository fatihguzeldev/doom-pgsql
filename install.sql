\set ON_ERROR_STOP on
BEGIN;
CREATE SCHEMA doom;
\ir engine/wad/archive.sql
\ir engine/world/schema.sql
\ir engine/wad/map.sql
\ir engine/wad/images.sql
\ir engine/world/geometry.sql
\ir engine/wad/load.sql
COMMIT;
