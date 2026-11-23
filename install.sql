\set ON_ERROR_STOP on
BEGIN;
CREATE SCHEMA doom;
\ir engine/wad/archive.sql
\ir engine/world/schema.sql
\ir engine/wad/map.sql
\ir engine/wad/images.sql
\ir engine/world/geometry.sql
\ir engine/wad/load.sql
\ir engine/simulation/game.sql
\ir engine/simulation/trace.sql
\ir engine/simulation/actions.sql
\ir engine/simulation/tick.sql
\ir engine/simulation/submit.sql
\ir engine/render/portals.sql
\ir engine/render/raster.sql
COMMIT;
