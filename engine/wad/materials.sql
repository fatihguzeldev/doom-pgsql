CREATE FUNCTION doom._wad_sky_name(p_level_name text)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
RETURN (
    SELECT CASE
        WHEN name ~ '^E[234]M' THEN 'SKY' || substring(name FROM 2 FOR 1)
        WHEN name ~ '^MAP(1[2-9]|20)' THEN 'SKY2'
        WHEN name ~ '^MAP(2[1-9]|3[0-2])' THEN 'SKY3'
        ELSE 'SKY1' END
    FROM (VALUES (upper(replace(p_level_name, ' ', '') COLLATE "C"))) AS level(name)
);

CREATE FUNCTION doom._import_wad_materials(p_level_id bigint, p_wad bytea)
RETURNS void
LANGUAGE plpgsql STRICT
AS $$
DECLARE
    wall_names text[];
    flat_names text[];
    playpal bytea;
    colormap bytea;
    material record;
    flat_coverage constant bytea := decode(repeat('ff', 4096), 'hex');
    inserted integer;
BEGIN
    SELECT array_agg(DISTINCT material_name ORDER BY material_name)
    INTO wall_names
    FROM (
        SELECT material_name
        FROM doom.wad_sidedefs AS side
        CROSS JOIN LATERAL (VALUES (side.upper_material), (side.lower_material), (side.middle_material))
            AS surface(material_name)
        WHERE side.level_id = p_level_id AND material_name IS NOT NULL

        UNION ALL

        SELECT doom._wad_sky_name(level.name)
        FROM doom.levels AS level
        WHERE level.level_id = p_level_id AND EXISTS (
            SELECT FROM doom.sectors AS sector
            WHERE sector.level_id = level.level_id AND sector.ceiling_material = 'F_SKY1'
        )
    ) AS walls;

    SELECT array_agg(DISTINCT material_name ORDER BY material_name)
    INTO flat_names
    FROM doom.sectors AS sector
    CROSS JOIN LATERAL (VALUES (sector.floor_material), (sector.ceiling_material)) AS surface(material_name)
    WHERE sector.level_id = p_level_id AND material_name IS NOT NULL;

    playpal := doom.wad_playpal(p_wad);
    colormap := doom.wad_lump(p_wad, 'COLORMAP');
    IF colormap IS NULL OR octet_length(colormap) < 256 OR octet_length(colormap) % 256 <> 0 THEN
        RAISE EXCEPTION 'COLORMAP must contain complete 256-entry light maps' USING ERRCODE = '22023';
    END IF;

    INSERT INTO doom.level_palettes (level_id, palette, playpal, colormap)
    VALUES (p_level_id, substring(playpal FOR 768), playpal, colormap);

    IF wall_names IS NOT NULL THEN
        INSERT INTO doom.level_materials (level_id, surface_kind, name, width, height, pixels, coverage)
        SELECT p_level_id, 'wall', texture.name, texture.width, texture.height, texture.pixels, texture.coverage
        FROM doom.wad_textures(p_wad, wall_names) AS texture;
    END IF;

    -- Last matching flat wins within its namespace. Unmarked resource archives also work.
    WITH directory AS MATERIALIZED (
        SELECT entry.*, sum(CASE
            WHEN data_size = 0 AND name IN ('F_START', 'FF_START') THEN 1
            WHEN data_size = 0 AND name IN ('F_END', 'FF_END') THEN -1
            ELSE 0 END) OVER (ORDER BY ordinal) AS flat_depth
        FROM (
            SELECT ordinal, upper(name COLLATE "C") AS name, data_offset, data_size
            FROM doom.wad_directory(p_wad)
        ) AS entry
    ), flats AS (
        SELECT DISTINCT ON (name) name, data_offset, data_size
        FROM directory WHERE name = ANY (flat_names)
        ORDER BY name, flat_depth > 0 DESC, ordinal DESC
    )
    INSERT INTO doom.level_materials (level_id, surface_kind, name, width, height, pixels, coverage)
    SELECT p_level_id, 'flat', name, 64, 64, substring(p_wad FROM data_offset + 1 FOR 4096), flat_coverage
    FROM flats WHERE data_size = 4096;

    GET DIAGNOSTICS inserted = ROW_COUNT;
    IF inserted <> coalesce(cardinality(flat_names), 0) THEN
        RAISE EXCEPTION 'referenced WAD flat is missing or has an invalid size' USING ERRCODE = '22023';
    END IF;

    FOR material IN
        WITH directory AS (
            SELECT entry.*, sum(CASE
                WHEN data_size = 0 AND name IN ('S_START', 'SS_START') THEN 1
                WHEN data_size = 0 AND name IN ('S_END', 'SS_END') THEN -1
                ELSE 0 END) OVER (ORDER BY ordinal) AS sprite_depth
            FROM (
                SELECT ordinal, upper(name COLLATE "C") AS name, data_offset, data_size
                FROM doom.wad_directory(p_wad)
            ) AS entry
        )
        SELECT DISTINCT ON (name) name, data_offset, data_size
        FROM directory WHERE sprite_depth > 0 AND data_size > 0
        ORDER BY name, ordinal DESC
    LOOP
        INSERT INTO doom.level_materials (level_id, surface_kind, name, width, height,
                                          left_offset, top_offset, pixels, coverage)
        SELECT p_level_id, 'sprite', material.name, patch.width, patch.height,
               patch.left_offset, patch.top_offset, patch.pixels, patch.coverage
        FROM doom.wad_patch(substring(p_wad FROM material.data_offset + 1 FOR material.data_size)) AS patch;
    END LOOP;
END;
$$;

CREATE FUNCTION doom.import_wad_level(p_wad bytea, p_level_name text)
RETURNS bigint
LANGUAGE plpgsql STRICT
AS $$
DECLARE
    imported_level_id bigint := doom.import_wad_geometry(p_wad, p_level_name);
BEGIN
    PERFORM doom._import_wad_materials(imported_level_id, p_wad);
    RETURN imported_level_id;
END;
$$;
