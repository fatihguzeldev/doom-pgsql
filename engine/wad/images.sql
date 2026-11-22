CREATE FUNCTION doom.wad_lump(p_wad bytea, p_name text)
RETURNS bytea
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
RETURN (
    SELECT CASE WHEN data_size = 0 THEN '\x'::bytea
                ELSE substring(p_wad FROM data_offset + 1 FOR data_size) END
    FROM doom.wad_directory(p_wad)
    WHERE upper(name COLLATE "C") = upper(p_name COLLATE "C")
    ORDER BY ordinal DESC
    LIMIT 1
);

CREATE FUNCTION doom.wad_playpal(p_wad bytea)
RETURNS bytea
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
AS $$
DECLARE
    palette bytea := doom.wad_lump(p_wad, 'PLAYPAL');
    palette_size integer := octet_length(palette);
BEGIN
    IF palette IS NULL OR palette_size = 0 OR palette_size % 768 <> 0 THEN
        RAISE EXCEPTION 'PLAYPAL must contain complete 256-color RGB palettes' USING ERRCODE = '22023';
    END IF;
    RETURN palette;
END;
$$;

CREATE FUNCTION doom.wad_patch(p_patch bytea)
RETURNS TABLE(width integer, height integer, left_offset integer, top_offset integer,
              pixels bytea, coverage bytea)
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
AS $$
DECLARE
    patch_size integer := octet_length(p_patch);
    header bytea := substring(p_patch FOR 8);
    directory_end integer;
    column_index integer;
    post_offset integer;
    post_y integer;
    post_size integer;
    transparent_column bytea;
    opaque_run constant bytea := decode(repeat('ff', 255), 'hex');
    column_pixels bytea;
    column_coverage bytea;
    pixel_columns bytea[] := '{}';
    coverage_columns bytea[] := '{}';
BEGIN
    IF patch_size < 8 THEN
        RAISE EXCEPTION 'truncated WAD patch header' USING ERRCODE = '22023';
    END IF;

    width := doom.wad_i16(header, 0);
    height := doom.wad_i16(header, 2);
    left_offset := doom.wad_i16(header, 4);
    top_offset := doom.wad_i16(header, 6);
    -- Bound the two dense output planes even for mostly transparent input.
    IF width <= 0 OR height <= 0 OR width * height > 16 * 1024 * 1024 THEN
        RAISE EXCEPTION 'invalid or oversized WAD patch dimensions' USING ERRCODE = '22023';
    END IF;

    directory_end := 8 + 4 * width;
    IF directory_end > patch_size THEN
        RAISE EXCEPTION 'truncated WAD patch column directory' USING ERRCODE = '22023';
    END IF;

    -- Materialize a toasted patch once before walking its posts.
    p_patch := substring(p_patch FROM 1);
    transparent_column := decode(repeat('00', height), 'hex');
    FOR column_index IN 0..(width - 1) LOOP
        post_offset := doom.wad_i32(p_patch, 8 + 4 * column_index);
        IF post_offset < directory_end OR post_offset >= patch_size THEN
            RAISE EXCEPTION 'invalid WAD patch column offset at column %', column_index USING ERRCODE = '22023';
        END IF;

        column_pixels := transparent_column;
        column_coverage := transparent_column;
        LOOP
            IF post_offset >= patch_size THEN
                RAISE EXCEPTION 'unterminated WAD patch column %', column_index USING ERRCODE = '22023';
            END IF;
            post_y := get_byte(p_patch, post_offset);
            EXIT WHEN post_y = 255;
            IF post_offset + 4 > patch_size THEN
                RAISE EXCEPTION 'truncated WAD patch post in column %', column_index USING ERRCODE = '22023';
            END IF;

            post_size := get_byte(p_patch, post_offset + 1);
            IF post_y + post_size > height OR post_offset + 4 + post_size > patch_size THEN
                RAISE EXCEPTION 'WAD patch post exceeds bounds in column %', column_index USING ERRCODE = '22023';
            END IF;

            IF post_size > 0 THEN
                column_pixels := overlay(column_pixels
                    PLACING substring(p_patch FROM post_offset + 4 FOR post_size)
                    FROM post_y + 1 FOR post_size);
                column_coverage := overlay(column_coverage PLACING substring(opaque_run FOR post_size)
                    FROM post_y + 1 FOR post_size);
            END IF;
            post_offset := post_offset + 4 + post_size;
        END LOOP;
        pixel_columns := array_append(pixel_columns, column_pixels);
        coverage_columns := array_append(coverage_columns, column_coverage);
    END LOOP;

    -- Both output planes use the zero-based sample index x * height + y.
    SELECT string_agg(columns.pixel_bytes, '\x'::bytea ORDER BY columns.ordinality),
           string_agg(columns.coverage_bytes, '\x'::bytea ORDER BY columns.ordinality)
    INTO pixels, coverage
    FROM unnest(pixel_columns, coverage_columns) WITH ORDINALITY AS columns(pixel_bytes, coverage_bytes);
    RETURN NEXT;
END;
$$;
