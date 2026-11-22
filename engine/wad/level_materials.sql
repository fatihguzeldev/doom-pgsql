CREATE TABLE doom.level_palettes (
    level_id bigint PRIMARY KEY REFERENCES doom.levels ON DELETE CASCADE,
    palette bytea NOT NULL CHECK (octet_length(palette) = 768)
);

CREATE TABLE doom.level_materials (
    level_id bigint NOT NULL REFERENCES doom.levels ON DELETE CASCADE,
    surface_kind text NOT NULL CHECK (surface_kind IN ('wall', 'flat', 'sprite')),
    name text NOT NULL CHECK (name <> ''),
    width integer NOT NULL CHECK (width > 0),
    height integer NOT NULL CHECK (height > 0),
    left_offset integer NOT NULL DEFAULT 0,
    top_offset integer NOT NULL DEFAULT 0,
    pixels bytea NOT NULL CHECK (octet_length(pixels) = width::bigint * height),
    coverage bytea NOT NULL CHECK (octet_length(coverage) = width::bigint * height),
    PRIMARY KEY (level_id, surface_kind, name)
);

CREATE FUNCTION doom.import_wad_materials(p_level_id bigint, p_wad bytea)
RETURNS void
LANGUAGE plpgsql STRICT
AS $$
DECLARE
    wall_names text[];
    flat_names text[];
    palette_location integer[];
    flat_locations jsonb;
    flat_location jsonb;
    flat_name text;
    flat_data bytea;
    flat_pixels bytea;
    flat_coverage constant bytea := decode(repeat('ff', 4096), 'hex');
BEGIN
    PERFORM 1 FROM doom.levels WHERE level_id = p_level_id FOR NO KEY UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'level % does not exist', p_level_id USING ERRCODE = '22023';
    END IF;

    WITH referenced_names AS (
        SELECT 'wall' AS surface_kind, upper(binding.name COLLATE "C") AS name
        FROM doom.line_surfaces AS surface
        CROSS JOIN LATERAL (VALUES (surface.upper_material), (surface.lower_material),
                                   (surface.middle_material)) AS binding(name)
        WHERE surface.level_id = p_level_id AND binding.name IS NOT NULL
        UNION
        SELECT 'flat', upper(binding.name COLLATE "C")
        FROM doom.sectors AS sector
        CROSS JOIN LATERAL (VALUES (sector.floor_material), (sector.ceiling_material)) AS binding(name)
        WHERE sector.level_id = p_level_id AND binding.name IS NOT NULL
    )
    SELECT array_agg(name ORDER BY name) FILTER (WHERE surface_kind = 'wall'),
           array_agg(name ORDER BY name) FILTER (WHERE surface_kind = 'flat')
    INTO wall_names, flat_names
    FROM referenced_names;

    -- Prefer a matching flat inside a marked range, while allowing resource-only archives.
    WITH directory AS MATERIALIZED (
        SELECT entry.*, sum(CASE
            WHEN data_size = 0 AND name IN ('F_START', 'FF_START') THEN 1
            WHEN data_size = 0 AND name IN ('F_END', 'FF_END') THEN -1
            ELSE 0
        END) OVER (ORDER BY ordinal) AS flat_depth
        FROM (
            SELECT ordinal, upper(name COLLATE "C") AS name, data_offset, data_size
            FROM doom.wad_directory(p_wad)
        ) AS entry
    )
    SELECT (SELECT ARRAY[data_offset, data_size] FROM directory
            WHERE name = 'PLAYPAL' ORDER BY ordinal DESC LIMIT 1),
           (SELECT jsonb_object_agg(name, jsonb_build_array(data_offset, data_size)
                                    ORDER BY flat_depth > 0, ordinal)
            FROM directory WHERE name = ANY (flat_names))
    INTO palette_location, flat_locations;

    IF palette_location IS NULL OR palette_location[2] = 0 OR palette_location[2] % 768 <> 0 THEN
        RAISE EXCEPTION 'PLAYPAL must contain complete 256-color RGB palettes' USING ERRCODE = '22023';
    END IF;

    INSERT INTO doom.level_palettes (level_id, palette)
    VALUES (p_level_id, substring(p_wad FROM palette_location[1] + 1 FOR 768))
    ON CONFLICT (level_id) DO UPDATE SET palette = EXCLUDED.palette;
    DELETE FROM doom.level_materials WHERE level_id = p_level_id AND surface_kind IN ('wall', 'flat');

    IF wall_names IS NOT NULL THEN
        INSERT INTO doom.level_materials (level_id, surface_kind, name, width, height, pixels, coverage)
        SELECT p_level_id, 'wall', texture.name, texture.width, texture.height, texture.pixels, texture.coverage
        FROM doom.wad_textures(p_wad, wall_names) AS texture;
    END IF;

    FOREACH flat_name IN ARRAY coalesce(flat_names, '{}'::text[]) LOOP
        flat_location := flat_locations -> flat_name;
        IF (flat_location ->> 1)::integer IS DISTINCT FROM 4096 THEN
            RAISE EXCEPTION 'WAD flat % must contain a 64 by 64 indexed image', flat_name USING ERRCODE = '22023';
        END IF;

        flat_data := substring(p_wad FROM (flat_location ->> 0)::integer + 1 FOR 4096);
        -- WAD flats are row-major. Publish the column-major layout shared by wall textures.
        SELECT string_agg(substring(flat_data FROM (sample % 64) * 64 + sample / 64 + 1 FOR 1),
                          '\x'::bytea ORDER BY sample)
        INTO flat_pixels
        FROM generate_series(0, 4095) AS samples(sample);

        INSERT INTO doom.level_materials (level_id, surface_kind, name, width, height, pixels, coverage)
        VALUES (p_level_id, 'flat', flat_name, 64, 64, flat_pixels, flat_coverage);
    END LOOP;
END;
$$;
