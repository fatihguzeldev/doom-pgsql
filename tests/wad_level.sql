BEGIN;

DO $$
DECLARE
    archive bytea := decode(
        -- The directory starts after the four geometry lumps.
        '50574144 0b000000 c2000000' ||
        -- LINEDEFS at byte 12
        '0000 0100 0100 0000 0000 0000 ffff' ||
        '0100 0200 0400 0000 0000 0100 0200' ||
        -- SIDEDEFS at byte 40. Only the sector references are populated.
        repeat('00', 28) || '0000' ||
        repeat('00', 28) || '0100' ||
        repeat('00', 28) || '0000' ||
        -- VERTEXES at byte 130
        'c0ff e0ff 4000 e0ff 4000 4000' ||
        -- SECTORS at byte 142
        'f0ff 6000' || repeat('00', 16) || '8000 0000 0000' ||
        '0800 7000' || repeat('00', 16) || 'c000 0000 0000' ||
        -- Directory at byte 194
        '00000000 00000000 544553544d415000' || -- TESTMAP
        '00000000 00000000 5448494e47530000' || -- THINGS
        '0c000000 1c000000 4c494e4544454653' || -- LINEDEFS
        '28000000 5a000000 5349444544454653' || -- SIDEDEFS
        '82000000 0c000000 5645525445584553' || -- VERTEXES
        '00000000 00000000 5345475300000000' || -- SEGS
        '00000000 00000000 53534543544f5253' || -- SSECTORS
        '00000000 00000000 4e4f444553000000' || -- NODES
        '8e000000 34000000 534543544f525300' || -- SECTORS
        '00000000 00000000 52454a4543540000' || -- REJECT
        '00000000 00000000 424c4f434b4d4150',   -- BLOCKMAP
        'hex'
    );
    imported_level bigint;
    sector_rows integer[];
    line_rows integer[];
    level_count bigint;
    invalid record;
BEGIN
    imported_level := doom.import_wad_level(archive, 'testmap');

    IF (SELECT name FROM doom.levels WHERE level_id = imported_level) IS DISTINCT FROM 'TESTMAP' THEN
        RAISE EXCEPTION 'import did not publish the requested level';
    END IF;

    SELECT array_agg(ARRAY[sector_id, floor_height, ceiling_height, light_level::integer]
                     ORDER BY sector_id)
    INTO sector_rows
    FROM doom.sectors WHERE level_id = imported_level;
    IF sector_rows IS DISTINCT FROM ARRAY[[0, -16, 96, 128], [1, 8, 112, 192]] THEN
        RAISE EXCEPTION 'incorrect imported sectors: %', sector_rows;
    END IF;

    SELECT array_agg(ARRAY[line_id, x1, y1, x2, y2, front_sector_id, back_sector_id, blocking::integer]
                     ORDER BY line_id)
    INTO line_rows
    FROM doom.lines WHERE level_id = imported_level;
    IF line_rows IS DISTINCT FROM ARRAY[
        [0, -64, -32, 64, -32, 0, NULL, 1],
        [1, 64, -32, 64, 64, 1, 0, 0]
    ] THEN
        RAISE EXCEPTION 'incorrect imported lines: %', line_rows;
    END IF;

    SELECT count(*) INTO level_count FROM doom.levels;
    FOR invalid IN
        SELECT * FROM (VALUES
            ('unknown level', archive, 'UNKNOWN'),
            ('blank level name',
                overlay(archive PLACING decode(repeat('00', 8), 'hex') FROM 203), ''),
            ('missing classic lump', set_byte(archive, 234, 88), 'TESTMAP'),
            ('partial linedef', set_byte(archive, 230, 27), 'TESTMAP'),
            ('missing vertex', set_byte(archive, 14, 3), 'TESTMAP'),
            ('missing front sidedef', set_byte(archive, 22, 3), 'TESTMAP'),
            ('missing back sidedef', set_byte(archive, 38, 3), 'TESTMAP'),
            ('missing sector', set_byte(archive, 68, 2), 'TESTMAP'),
            ('Hexen-style map',
                set_byte(archive, 4, 12) || decode('00000000 00000000 4245484156494f52', 'hex'),
                'TESTMAP')
        ) AS cases(label, bytes, map_name)
    LOOP
        BEGIN
            PERFORM doom.import_wad_level(invalid.bytes, invalid.map_name);
            RAISE EXCEPTION 'WAD importer accepted %', invalid.label;
        EXCEPTION WHEN invalid_parameter_value THEN
            NULL;
        END;
    END LOOP;

    IF (SELECT count(*) FROM doom.levels) <> level_count THEN
        RAISE EXCEPTION 'a failed WAD import published a partial level';
    END IF;
END;
$$;

ROLLBACK;
