\set ON_ERROR_STOP on
BEGIN;
\ir wad.sql
\ir wad_level.sql
\ir wad_spatial.sql
\ir wad_materials.sql
\ir wad_textures.sql
ROLLBACK;
\ir simulation.sql
\ir render_atlas.sql
\ir render.sql
