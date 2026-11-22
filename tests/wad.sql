DO $$
DECLARE
    archive bytea := decode(
        '50574144 03000000 10000000' ||
        'aabbccdd' ||
        '0e000000 02000000 4455500000000000' ||
        'ffffffff 00000000 4d41524b45523030' ||
        '0c000000 03000000 4455500058795a00',
        'hex'
    );
    parsed text[];
    invalid record;
BEGIN
    SELECT array_agg(ARRAY[ordinal::text, name, data_offset::text, data_size::text]
                     ORDER BY ordinal)
    INTO parsed
    FROM doom.wad_directory(archive);

    IF parsed IS DISTINCT FROM ARRAY[
        ['0', 'DUP', '14', '2'],
        ['1', 'MARKER00', '-1', '0'],
        ['2', 'DUP', '12', '3']
    ] THEN
        RAISE EXCEPTION 'unexpected WAD directory: %', parsed;
    END IF;

    IF EXISTS (SELECT FROM doom.wad_directory(decode('49574144000000000c000000', 'hex'))) THEN
        RAISE EXCEPTION 'an empty IWAD has no directory entries';
    END IF;

    IF doom.wad_u16(decode('34ff', 'hex'), 0) <> 65332
        OR doom.wad_i16(decode('000080', 'hex'), 1) <> -32768
        OR doom.wad_i32(decode('010000807f', 'hex'), 0) <> -2147483647
        OR doom.wad_i32(decode('00ffffff7f', 'hex'), 1) <> 2147483647
    THEN
        RAISE EXCEPTION 'incorrect little-endian decoding';
    END IF;

    FOR invalid IN
        SELECT * FROM (VALUES
            ('short header', substring(archive FOR 11)),
            ('unrecognized signature', set_byte(archive, 0, 88)),
            ('negative directory count', set_byte(archive, 7, 128)),
            ('oversized directory count', overlay(archive PLACING decode('ffffff7f', 'hex') FROM 5)),
            ('directory overlaps header', set_byte(archive, 8, 8)),
            ('directory overflows offset', overlay(archive PLACING decode('ffffff7f', 'hex') FROM 9)),
            ('truncated directory', substring(archive FOR 63)),
            ('negative lump size', set_byte(archive, 23, 128)),
            ('negative offset to lump data', set_byte(archive, 19, 128)),
            ('lump data exceeds file size', set_byte(archive, 20, 60)),
            ('lump data range exceeds integer',
                overlay(archive PLACING decode('ffffff7fffffff7f', 'hex') FROM 17))
        ) AS cases(label, bytes)
    LOOP
        BEGIN
            PERFORM * FROM doom.wad_directory(invalid.bytes);
            RAISE EXCEPTION 'WAD decoder accepted %', invalid.label;
        EXCEPTION WHEN invalid_parameter_value THEN
            NULL;
        END;
    END LOOP;
END;
$$;
