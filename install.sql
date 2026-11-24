\set ON_ERROR_STOP on
BEGIN;
CREATE SCHEMA doom;
\ir engine/wad/archive.sql
\ir engine/world/schema.sql
\ir engine/world/art.sql
\ir engine/world/thing_types.sql
\ir engine/wad/map.sql
\ir engine/wad/images.sql
\ir engine/world/geometry.sql
\ir engine/wad/load.sql
\ir engine/wad/prepared.sql
\ir engine/simulation/game.sql
\ir engine/simulation/edits.sql
\ir engine/simulation/trace.sql
\ir engine/simulation/spawn.sql
\ir engine/simulation/actions.sql
\ir engine/simulation/sound.sql
\ir engine/simulation/tick.sql
\ir engine/simulation/submit.sql
\ir engine/render/catalog.sql
\ir engine/render/walls.sql
\ir engine/render/planes.sql
\ir engine/render/palette.sql
\ir engine/render/scenes.sql
\ir engine/render/frame.sql
\ir engine/render/cache.sql
COMMIT;
