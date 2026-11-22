\set ON_ERROR_STOP on
BEGIN;
CREATE SCHEMA doom;
\ir engine/wad.sql
\ir engine/simulation.sql
\ir engine/frame_atlas.sql
\ir engine/render.sql

CREATE FUNCTION doom.load_wad(p_wad bytea, p_map text)
RETURNS bigint LANGUAGE plpgsql STRICT AS $$
DECLARE
    level bigint;
BEGIN
    level := doom.import_wad_level(p_wad, p_map);
    PERFORM doom.compile_frame_assets(level);
    PERFORM doom._compile_flat_atlas(level);
    RETURN level;
END;
$$;
COMMIT;
