\set ON_ERROR_STOP on

BEGIN;
CREATE SCHEMA doom;
\ir engine/world/world.sql
\ir engine/wad/directory.sql
\ir engine/wad/level.sql
\ir engine/simulation/movement.sql
\ir engine/simulation/tick.sql
COMMIT;
