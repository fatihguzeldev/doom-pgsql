\set ON_ERROR_STOP on

BEGIN;
CREATE SCHEMA doom;
\ir engine/world/world.sql
\ir engine/wad/directory.sql
\ir engine/wad/level.sql
\ir engine/wad/materials.sql
\ir engine/wad/textures.sql
\ir engine/simulation/movement.sql
\ir engine/simulation/tick.sql
\ir engine/renderer/render.sql
\ir engine/step.sql
COMMIT;
