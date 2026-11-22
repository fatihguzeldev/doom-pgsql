CREATE FUNCTION doom.wad_material_name(p_field bytea)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
RETURN (
    SELECT CASE WHEN btrim(name) IN ('', '-') THEN NULL ELSE upper(name COLLATE "C") END
    FROM (VALUES (doom.wad_name(p_field))) AS decoded(name)
);

CREATE FUNCTION doom.import_wad_geometry(p_wad bytea, p_level_name text)
RETURNS bigint
LANGUAGE plpgsql STRICT
AS $$
DECLARE
    expected_lumps constant text[] := ARRAY[
        'THINGS', 'LINEDEFS', 'SIDEDEFS', 'VERTEXES', 'SEGS',
        'SSECTORS', 'NODES', 'SECTORS', 'REJECT', 'BLOCKMAP'
    ];
    level_name text := upper(p_level_name COLLATE "C");
    lump_names text[];
    lump_data bytea[];
    thing_data bytea;
    line_data bytea;
    side_data bytea;
    vertex_data bytea;
    sector_data bytea;
    line_count integer;
    inserted integer;
    imported_level_id bigint;
BEGIN
    IF level_name = '' THEN
        RAISE EXCEPTION 'WAD map name is required' USING ERRCODE = '22023';
    END IF;

    WITH directory AS MATERIALIZED (
        SELECT ordinal, upper(name COLLATE "C") AS name, data_offset, data_size
        FROM doom.wad_directory(p_wad)
    ), marker AS (
        SELECT max(ordinal) AS ordinal FROM directory WHERE name = level_name
    )
    SELECT array_agg(directory.name ORDER BY directory.ordinal),
           array_agg(CASE WHEN data_size = 0 THEN '\x'::bytea
                          ELSE substring(p_wad FROM data_offset + 1 FOR data_size) END
                     ORDER BY directory.ordinal)
    INTO lump_names, lump_data
    FROM directory, marker
    WHERE directory.ordinal BETWEEN marker.ordinal + 1 AND marker.ordinal + 11;

    IF lump_names[1:10] IS DISTINCT FROM expected_lumps OR lump_names[11] = 'BEHAVIOR' THEN
        RAISE EXCEPTION 'classic WAD map % is missing or has an unsupported lump layout', level_name
            USING ERRCODE = '22023';
    END IF;

    thing_data := lump_data[1];
    line_data := lump_data[2];
    side_data := lump_data[3];
    vertex_data := lump_data[4];
    sector_data := lump_data[8];
    line_count := octet_length(line_data) / 14;

    IF octet_length(thing_data) % 10 <> 0
        OR octet_length(line_data) % 14 <> 0 OR line_count NOT BETWEEN 1 AND 65536
        OR octet_length(side_data) % 30 <> 0 OR octet_length(side_data) / 30 NOT BETWEEN 1 AND 65535
        OR octet_length(vertex_data) % 4 <> 0 OR octet_length(vertex_data) / 4 NOT BETWEEN 1 AND 65536
        OR octet_length(sector_data) % 26 <> 0 OR octet_length(sector_data) / 26 NOT BETWEEN 1 AND 65536
    THEN
        RAISE EXCEPTION 'invalid geometry record sizes in WAD map %', level_name USING ERRCODE = '22023';
    END IF;

    INSERT INTO doom.levels (name) VALUES (level_name) RETURNING level_id INTO imported_level_id;

    INSERT INTO doom.wad_vertices (level_id, vertex_id, x, y)
    SELECT imported_level_id, id, doom.wad_i16(vertex_data, id * 4), doom.wad_i16(vertex_data, id * 4 + 2)
    FROM generate_series(0, octet_length(vertex_data) / 4 - 1) AS vertex(id);

    WITH decoded AS MATERIALIZED (
        SELECT id, doom.wad_i16(sector_data, id * 26) AS floor_height,
               doom.wad_i16(sector_data, id * 26 + 2) AS ceiling_height,
               doom.wad_i16(sector_data, id * 26 + 20) AS light_level,
               doom.wad_material_name(substring(sector_data FROM id * 26 + 5 FOR 8)) AS floor_material,
               doom.wad_material_name(substring(sector_data FROM id * 26 + 13 FOR 8)) AS ceiling_material,
               doom.wad_u16(sector_data, id * 26 + 22) AS special,
               doom.wad_u16(sector_data, id * 26 + 24) AS tag
        FROM generate_series(0, octet_length(sector_data) / 26 - 1) AS sector(id)
    )
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height, light_level,
                              floor_material, ceiling_material, special, tag)
    SELECT imported_level_id, id, floor_height, ceiling_height, light_level,
           floor_material, ceiling_material, special, tag
    FROM decoded WHERE floor_height <= ceiling_height AND light_level BETWEEN 0 AND 255;

    GET DIAGNOSTICS inserted = ROW_COUNT;
    IF inserted <> octet_length(sector_data) / 26 THEN
        RAISE EXCEPTION 'invalid sector height or lighting in WAD map %', level_name USING ERRCODE = '22023';
    END IF;

    INSERT INTO doom.wad_sidedefs (level_id, side_id, sector_id, x_offset, y_offset,
                                  upper_material, lower_material, middle_material)
    SELECT imported_level_id, id, doom.wad_u16(side_data, id * 30 + 28),
           doom.wad_i16(side_data, id * 30), doom.wad_i16(side_data, id * 30 + 2),
           doom.wad_material_name(substring(side_data FROM id * 30 + 5 FOR 8)),
           doom.wad_material_name(substring(side_data FROM id * 30 + 13 FOR 8)),
           doom.wad_material_name(substring(side_data FROM id * 30 + 21 FOR 8))
    FROM generate_series(0, octet_length(side_data) / 30 - 1) AS side(id)
    WHERE doom.wad_u16(side_data, id * 30 + 28) < octet_length(sector_data) / 26;

    GET DIAGNOSTICS inserted = ROW_COUNT;
    IF inserted <> octet_length(side_data) / 30 THEN
        RAISE EXCEPTION 'invalid sidedef sector reference in WAD map %', level_name USING ERRCODE = '22023';
    END IF;

    WITH decoded AS MATERIALIZED (
        SELECT id, doom.wad_u16(line_data, id * 14) AS first_vertex,
               doom.wad_u16(line_data, id * 14 + 2) AS second_vertex,
               doom.wad_u16(line_data, id * 14 + 4) AS flags,
               doom.wad_u16(line_data, id * 14 + 6) AS special,
               doom.wad_u16(line_data, id * 14 + 8) AS tag,
               doom.wad_u16(line_data, id * 14 + 10) AS first_side,
               nullif(doom.wad_u16(line_data, id * 14 + 12), 65535) AS second_side
        FROM generate_series(0, line_count - 1) AS line(id)
    )
    INSERT INTO doom.lines (level_id, line_id, first_vertex_id, second_vertex_id, x1, y1, x2, y2,
                            front_sector_id, back_sector_id, front_side_id, back_side_id,
                            flags, special, tag, blocking)
    SELECT imported_level_id, line.id, line.first_vertex, line.second_vertex,
           start.x, start.y, finish.x, finish.y, front.sector_id, back.sector_id, front.side_id, back.side_id,
           line.flags, line.special, line.tag, back.side_id IS NULL OR (line.flags & 1) <> 0 OR (line.flags & 4) = 0
    FROM decoded AS line
    JOIN doom.wad_vertices AS start ON start.level_id = imported_level_id AND start.vertex_id = line.first_vertex
    JOIN doom.wad_vertices AS finish ON finish.level_id = imported_level_id AND finish.vertex_id = line.second_vertex
    JOIN doom.wad_sidedefs AS front ON front.level_id = imported_level_id AND front.side_id = line.first_side
    LEFT JOIN doom.wad_sidedefs AS back ON back.level_id = imported_level_id AND back.side_id = line.second_side
    WHERE (line.second_side IS NULL OR back.side_id IS NOT NULL)
      AND (start.x, start.y) <> (finish.x, finish.y);

    GET DIAGNOSTICS inserted = ROW_COUNT;
    IF inserted <> line_count THEN
        RAISE EXCEPTION 'invalid linedef references or coordinates in WAD map %', level_name USING ERRCODE = '22023';
    END IF;

    IF octet_length(lump_data[5]) + octet_length(lump_data[6]) + octet_length(lump_data[7]) > 0 THEN
        PERFORM doom._import_wad_bsp(imported_level_id, lump_data[5], lump_data[6], lump_data[7]);
    END IF;
    PERFORM doom._import_wad_blockmap(imported_level_id, lump_data[10], line_count);

    WITH decoded AS MATERIALIZED (
        SELECT id, doom.wad_i16(thing_data, id * 10) AS x, doom.wad_i16(thing_data, id * 10 + 2) AS y,
               doom.wad_i16(thing_data, id * 10 + 4) AS angle_deg,
               doom.wad_u16(thing_data, id * 10 + 6) AS type_code,
               doom.wad_u16(thing_data, id * 10 + 8) AS flags
        FROM generate_series(0, octet_length(thing_data) / 10 - 1) AS thing(id)
    )
    INSERT INTO doom.level_things (level_id, thing_id, x, y, angle_deg, type_code, flags, sector_id)
    SELECT imported_level_id, id, x, y, angle_deg, type_code, flags,
           doom.sector_at(imported_level_id, x, y)
    FROM decoded;

    RETURN imported_level_id;
END;
$$;
