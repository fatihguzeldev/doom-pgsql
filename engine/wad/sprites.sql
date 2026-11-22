CREATE FUNCTION doom.import_wad_sprites(p_level_id bigint, p_wad bytea, p_names text[])
RETURNS void
LANGUAGE plpgsql STRICT
AS $$
DECLARE
    requested_names text[];
    palette_location integer[];
    sprite_locations jsonb;
    sprite_name text;
    sprite_location jsonb;
    sprite_size integer;
BEGIN
    IF EXISTS (SELECT FROM unnest(p_names) AS request(label)
               WHERE label IS NULL OR length(label) NOT BETWEEN 1 AND 8) THEN
        RAISE EXCEPTION 'WAD sprite names must contain one to eight characters' USING ERRCODE = '22023';
    END IF;

    SELECT array_agg(DISTINCT label ORDER BY label) INTO requested_names
    FROM (SELECT upper(request.label COLLATE "C") AS label FROM unnest(p_names) AS request(label)) AS names;
    IF requested_names IS NULL THEN
        RETURN;
    END IF;

    PERFORM 1 FROM doom.levels WHERE level_id = p_level_id FOR NO KEY UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'level % does not exist', p_level_id USING ERRCODE = '22023';
    END IF;

    -- Prefer sprite namespaces while allowing standalone patch archives.
    WITH directory AS MATERIALIZED (
        SELECT entry.*, sum(CASE
            WHEN data_size = 0 AND name IN ('S_START', 'SS_START') THEN 1
            WHEN data_size = 0 AND name IN ('S_END', 'SS_END') THEN -1
            ELSE 0
        END) OVER (ORDER BY ordinal) AS sprite_depth
        FROM (
            SELECT ordinal, upper(name COLLATE "C") AS name, data_offset, data_size
            FROM doom.wad_directory(p_wad)
        ) AS entry
    )
    SELECT (SELECT ARRAY[data_offset, data_size] FROM directory
            WHERE name = 'PLAYPAL' ORDER BY ordinal DESC LIMIT 1),
           (SELECT jsonb_object_agg(name, jsonb_build_array(data_offset, data_size)
                                    ORDER BY sprite_depth > 0, ordinal)
            FROM directory WHERE name = ANY (requested_names))
    INTO palette_location, sprite_locations;

    IF NOT EXISTS (SELECT FROM doom.level_palettes WHERE level_id = p_level_id) THEN
        IF palette_location IS NULL OR palette_location[2] = 0 OR palette_location[2] % 768 <> 0 THEN
            RAISE EXCEPTION 'PLAYPAL must contain complete 256-color RGB palettes' USING ERRCODE = '22023';
        END IF;
        INSERT INTO doom.level_palettes (level_id, palette)
        VALUES (p_level_id, substring(p_wad FROM palette_location[1] + 1 FOR 768));
    END IF;

    FOREACH sprite_name IN ARRAY requested_names LOOP
        sprite_location := sprite_locations -> sprite_name;
        sprite_size := (sprite_location ->> 1)::integer;
        IF sprite_size IS NULL OR sprite_size = 0 THEN
            RAISE EXCEPTION 'missing or empty WAD sprite lump %', sprite_name USING ERRCODE = '22023';
        END IF;

        INSERT INTO doom.level_materials (level_id, surface_kind, name, width, height,
                                          left_offset, top_offset, pixels, coverage)
        SELECT p_level_id, 'sprite', sprite_name, patch.width, patch.height,
               patch.left_offset, patch.top_offset, patch.pixels, patch.coverage
        FROM doom.wad_patch(substring(p_wad FROM (sprite_location ->> 0)::integer + 1 FOR sprite_size)) AS patch
        ON CONFLICT (level_id, surface_kind, name) DO UPDATE
        SET width = EXCLUDED.width,
            height = EXCLUDED.height,
            left_offset = EXCLUDED.left_offset,
            top_offset = EXCLUDED.top_offset,
            pixels = EXCLUDED.pixels,
            coverage = EXCLUDED.coverage;
    END LOOP;
END;
$$;
