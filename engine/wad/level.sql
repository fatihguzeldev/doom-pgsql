CREATE FUNCTION doom.import_wad_level(p_wad bytea, p_level_name text)
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
    lump_offsets integer[];
    lump_sizes integer[];
    line_data bytea;
    side_data bytea;
    vertex_data bytea;
    sector_data bytea;
    line_count integer;
    side_count integer;
    vertex_count integer;
    sector_count integer;
    vertex_x integer[];
    vertex_y integer[];
    side_sector integer[];
    imported_level_id bigint;
    inserted_rows integer;
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
           array_agg(directory.data_offset ORDER BY directory.ordinal),
           array_agg(directory.data_size ORDER BY directory.ordinal)
    INTO lump_names, lump_offsets, lump_sizes
    FROM directory, marker
    WHERE directory.ordinal BETWEEN marker.ordinal + 1 AND marker.ordinal + 11;

    IF lump_names[1:10] IS DISTINCT FROM expected_lumps OR lump_names[11] = 'BEHAVIOR' THEN
        RAISE EXCEPTION 'classic WAD map % is missing or has an unsupported lump layout', level_name
            USING ERRCODE = '22023';
    END IF;

    line_count := lump_sizes[2] / 14;
    side_count := lump_sizes[3] / 30;
    vertex_count := lump_sizes[4] / 4;
    sector_count := lump_sizes[8] / 26;
    -- Map indices are 16-bit. The value 65535 represents a missing sidedef.
    IF lump_sizes[2] % 14 <> 0 OR line_count NOT BETWEEN 1 AND 65536
        OR lump_sizes[3] % 30 <> 0 OR side_count NOT BETWEEN 1 AND 65535
        OR lump_sizes[4] % 4 <> 0 OR vertex_count NOT BETWEEN 1 AND 65536
        OR lump_sizes[8] % 26 <> 0 OR sector_count NOT BETWEEN 1 AND 65536
    THEN
        RAISE EXCEPTION 'invalid geometry record sizes in WAD map %', level_name
            USING ERRCODE = '22023';
    END IF;

    line_data := substring(p_wad FROM lump_offsets[2] + 1 FOR lump_sizes[2]);
    side_data := substring(p_wad FROM lump_offsets[3] + 1 FOR lump_sizes[3]);
    vertex_data := substring(p_wad FROM lump_offsets[4] + 1 FOR lump_sizes[4]);
    sector_data := substring(p_wad FROM lump_offsets[8] + 1 FOR lump_sizes[8]);

    SELECT array_agg(doom.wad_i16(vertex_data, 4 * vertex_id) ORDER BY vertex_id),
           array_agg(doom.wad_i16(vertex_data, 4 * vertex_id + 2) ORDER BY vertex_id)
    INTO vertex_x, vertex_y
    FROM generate_series(0, vertex_count - 1) AS vertex(vertex_id);

    SELECT array_agg(doom.wad_u16(side_data, 30 * side_id + 28) ORDER BY side_id)
    INTO side_sector
    FROM generate_series(0, side_count - 1) AS side(side_id);
    IF EXISTS (SELECT FROM unnest(side_sector) AS side(sector_id) WHERE sector_id >= sector_count) THEN
        RAISE EXCEPTION 'invalid sidedef sector reference in WAD map %', level_name
            USING ERRCODE = '22023';
    END IF;

    INSERT INTO doom.levels (name) VALUES (level_name) RETURNING level_id INTO imported_level_id;

    WITH decoded AS MATERIALIZED (
        SELECT sector_id, doom.wad_i16(sector_data, 26 * sector_id) AS floor_height,
               doom.wad_i16(sector_data, 26 * sector_id + 2) AS ceiling_height,
               doom.wad_i16(sector_data, 26 * sector_id + 20) AS light_level
        FROM generate_series(0, sector_count - 1) AS sector(sector_id)
    )
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height, light_level)
    SELECT imported_level_id, sector_id, floor_height, ceiling_height, light_level
    FROM decoded
    WHERE floor_height <= ceiling_height AND light_level BETWEEN 0 AND 255;

    GET DIAGNOSTICS inserted_rows = ROW_COUNT;
    IF inserted_rows <> sector_count THEN
        RAISE EXCEPTION 'invalid sector height or light level in WAD map %', level_name
            USING ERRCODE = '22023';
    END IF;

    WITH decoded AS MATERIALIZED (
        SELECT line_id, doom.wad_u16(line_data, 14 * line_id) AS first_vertex,
               doom.wad_u16(line_data, 14 * line_id + 2) AS second_vertex,
               doom.wad_u16(line_data, 14 * line_id + 4) AS flags,
               doom.wad_u16(line_data, 14 * line_id + 10) AS front_side,
               doom.wad_u16(line_data, 14 * line_id + 12) AS back_side
        FROM generate_series(0, line_count - 1) AS line(line_id)
    ), resolved AS (
        SELECT line_id, vertex_x[first_vertex + 1] AS x1, vertex_y[first_vertex + 1] AS y1,
               vertex_x[second_vertex + 1] AS x2, vertex_y[second_vertex + 1] AS y2,
               side_sector[front_side + 1] AS front_sector_id,
               side_sector[nullif(back_side, 65535) + 1] AS back_sector_id,
               back_side = 65535 OR (flags & 1) <> 0 OR (flags & 4) = 0 AS blocking
        FROM decoded
        WHERE first_vertex < vertex_count AND second_vertex < vertex_count
          AND front_side < side_count AND (back_side < side_count OR back_side = 65535)
    )
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id, back_sector_id, blocking)
    SELECT imported_level_id, line_id, x1, y1, x2, y2, front_sector_id, back_sector_id, blocking
    FROM resolved
    WHERE x1 <> x2 OR y1 <> y2;

    GET DIAGNOSTICS inserted_rows = ROW_COUNT;
    IF inserted_rows <> line_count THEN
        RAISE EXCEPTION 'invalid linedef indices or identical endpoints in WAD map %', level_name
            USING ERRCODE = '22023';
    END IF;

    RETURN imported_level_id;
END;
$$;
