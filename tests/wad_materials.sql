DO $$
DECLARE
    main_palette bytea := decode(repeat('217fff', 256), 'hex');
    alternate_palette bytea := decode(repeat('aabbcc', 256), 'hex');
    archive bytea := decode('50574144 02000000 0c090000', 'hex')
        || decode(repeat('001122', 256), 'hex') || main_palette || alternate_palette
        || decode('0c000000 00030000 504c415950414c00' || '0c030000 00060000 706c617970616c00', 'hex');
    patch bytea := decode(
        -- A two-column patch with signed origin offsets.
        '0200 0500 ffff 0200 10000000 1c000000' ||
        '0001000000 030200ff8000 ff' ||
        '0101002a00 ff',
        'hex'
    );
    decoded record;
    invalid record;
BEGIN
    IF doom.wad_playpal(archive) IS DISTINCT FROM main_palette || alternate_palette THEN
        RAISE EXCEPTION 'PLAYPAL did not select the last case-insensitive lump';
    END IF;

    IF doom.wad_lump(archive, 'missing') IS NOT NULL THEN
        RAISE EXCEPTION 'an absent lump should return NULL';
    END IF;

    FOR invalid IN
        SELECT * FROM (VALUES
            ('missing palette', decode('49574144000000000c000000', 'hex')),
            ('incomplete palette', set_byte(archive, 2337, 5))
        ) AS cases(label, bytes)
    LOOP
        BEGIN
            PERFORM doom.wad_playpal(invalid.bytes);
            RAISE EXCEPTION 'WAD material reader accepted %', invalid.label;
        EXCEPTION WHEN invalid_parameter_value THEN
            NULL;
        END;
    END LOOP;

    SELECT * INTO decoded FROM doom.wad_patch(patch);
    IF ARRAY[decoded.width, decoded.height, decoded.left_offset, decoded.top_offset]
        IS DISTINCT FROM ARRAY[2, 5, -1, 2]
    THEN
        RAISE EXCEPTION 'incorrect patch dimensions or origin: %', decoded;
    END IF;

    IF decoded.pixels IS DISTINCT FROM decode('000000ff80 002a000000', 'hex')
        OR decoded.coverage IS DISTINCT FROM decode('ff0000ffff 00ff000000', 'hex')
    THEN
        RAISE EXCEPTION 'incorrect indexed pixel data or coverage: %', decoded;
    END IF;

    SELECT * INTO decoded FROM doom.wad_patch(set_byte(patch, 12, 16));
    IF decoded.pixels IS DISTINCT FROM decode('000000ff80 000000ff80', 'hex') THEN
        RAISE EXCEPTION 'column offsets should allow shared post streams';
    END IF;

    SELECT * INTO decoded FROM doom.wad_patch(set_byte(patch, 16, 255));
    IF decoded.coverage IS DISTINCT FROM decode('0000000000 00ff000000', 'hex') THEN
        RAISE EXCEPTION 'an empty column should be fully transparent';
    END IF;

    FOR invalid IN
        SELECT * FROM (VALUES
            ('short header', substring(patch FOR 7)),
            ('zero width', set_byte(patch, 0, 0)),
            ('negative height', set_byte(patch, 3, 128)),
            ('truncated column directory', substring(patch FOR 15)),
            ('pointer into column directory', set_byte(patch, 8, 15)),
            ('negative column pointer', set_byte(patch, 11, 128)),
            ('column pointer outside lump', set_byte(patch, 12, 255)),
            ('post beyond image height', set_byte(patch, 16, 5)),
            ('truncated post data', substring(patch FOR 32)),
            ('missing column terminator', substring(patch FOR 33)),
            ('truncated post header', set_byte(set_byte(patch, 12, 33), 33, 1))
        ) AS cases(label, bytes)
    LOOP
        BEGIN
            PERFORM * FROM doom.wad_patch(invalid.bytes);
            RAISE EXCEPTION 'WAD patch decoder accepted %', invalid.label;
        EXCEPTION WHEN invalid_parameter_value THEN
            NULL;
        END;
    END LOOP;
END;
$$;
