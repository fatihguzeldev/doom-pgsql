CREATE FUNCTION doom.wad_u16(p_data bytea, p_offset integer)
RETURNS integer
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
RETURN get_byte(p_data, p_offset) | (get_byte(p_data, p_offset + 1) << 8);

CREATE FUNCTION doom.wad_i16(p_data bytea, p_offset integer)
RETURNS integer
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
RETURN (doom.wad_u16(p_data, p_offset) # 32768) - 32768;

CREATE FUNCTION doom.wad_i32(p_data bytea, p_offset integer)
RETURNS integer
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
RETURN doom.wad_u16(p_data, p_offset)
    | (get_byte(p_data, p_offset + 2) << 16)
    | (get_byte(p_data, p_offset + 3) << 24);

CREATE FUNCTION doom.wad_name(p_field bytea)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
RETURN convert_from(
    substring(p_field FOR coalesce(nullif(position('\x00'::bytea IN p_field), 0) - 1,
                                       octet_length(p_field))),
    'LATIN1'
);

CREATE FUNCTION doom.wad_directory(p_wad bytea)
RETURNS TABLE(ordinal integer, name text, data_offset integer, data_size integer)
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
AS $$
DECLARE
    archive_size integer := octet_length(p_wad);
    header bytea := substring(p_wad FOR 12);
    directory bytea;
    entry_count integer;
    directory_offset integer;
    entry_ordinal integer;
    entry_offset integer;
BEGIN
    IF archive_size < 12 OR substring(header FOR 4) NOT IN ('\x49574144', '\x50574144') THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid WAD header';
    END IF;

    entry_count := doom.wad_i32(header, 4);
    directory_offset := doom.wad_i32(header, 8);
    IF entry_count < 0 OR directory_offset < 12
        OR directory_offset + 16::bigint * entry_count > archive_size
    THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'WAD directory is outside the archive';
    END IF;

    directory := substring(p_wad FROM directory_offset + 1 FOR 16 * entry_count);
    FOR entry_ordinal IN 0..(entry_count - 1) LOOP
        entry_offset := 16 * entry_ordinal;
        ordinal := entry_ordinal;
        data_offset := doom.wad_i32(directory, entry_offset);
        data_size := doom.wad_i32(directory, entry_offset + 4);

        -- A zero-sized marker has no payload, so its offset need not point into the archive.
        IF data_size < 0 OR (data_size > 0 AND
                            (data_offset < 0 OR data_offset::bigint + data_size > archive_size))
        THEN
            RAISE EXCEPTION USING ERRCODE = '22023',
                MESSAGE = format('WAD lump %s is outside the archive', ordinal);
        END IF;

        name := doom.wad_name(substring(directory FROM entry_offset + 9 FOR 8));
        RETURN NEXT;
    END LOOP;
END;
$$;
