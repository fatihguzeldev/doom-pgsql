\set ON_ERROR_STOP on

BEGIN;
CREATE SCHEMA doom;
\ir engine/world/world.sql
\ir engine/world/gates.sql
\ir engine/world/pursuits.sql
\ir engine/world/pickups.sql
\ir engine/world/level_things.sql
\ir engine/world/surfaces.sql
\ir engine/wad/directory.sql
\ir engine/wad/level.sql
\ir engine/wad/materials.sql
\ir engine/wad/textures.sql
\ir engine/wad/level_materials.sql
\ir engine/wad/sprites.sql
\ir engine/wad/actor_bindings.sql
\ir engine/simulation/collision.sql
\ir engine/simulation/movement.sql
\ir engine/simulation/actor_collision.sql
\ir engine/simulation/gates.sql
\ir engine/simulation/gate_use.sql
\ir engine/simulation/ray.sql
\ir engine/simulation/ray_targets.sql
\ir engine/simulation/wad_inventory.sql
\ir engine/simulation/fire.sql
\ir engine/simulation/pursuit.sql
\ir engine/simulation/pickups.sql
\ir engine/simulation/tick.sql
\ir engine/simulation/inputs.sql
\ir engine/simulation/level_start.sql
\ir engine/renderer/types.sql
\ir engine/renderer/materials.sql
\ir engine/renderer/masks.sql
\ir engine/renderer/render.sql
\ir engine/step.sql
COMMIT;
