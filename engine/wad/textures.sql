CREATE FUNCTION doom.wad_texture_records(p_catalog bytea)
RETURNS TABLE(ordinal bigint, name text, record_offset integer, record_end integer)
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
AS $$
DECLARE
    catalog_size integer := octet_length(p_catalog);
    record_count integer;
    directory_end integer;
    record_offsets integer[];
BEGIN
    IF catalog_size < 4 THEN
        RAISE EXCEPTION 'truncated WAD texture catalog' USING ERRCODE = '22023';
    END IF;
    record_count := doom.wad_i32(p_catalog, 0);
    IF record_count < 0 OR 4 + 4::bigint * record_count > catalog_size THEN
        RAISE EXCEPTION 'invalid WAD texture catalog size' USING ERRCODE = '22023';
    END IF;

    directory_end := 4 + 4 * record_count;
    SELECT array_agg(doom.wad_i32(p_catalog, 4 + 4 * entry_index) ORDER BY entry_index)
    INTO record_offsets
    FROM generate_series(0, record_count - 1) AS records(entry_index);

    IF EXISTS (
        SELECT FROM unnest(record_offsets) AS offsets(position)
        WHERE offsets.position < directory_end OR offsets.position > catalog_size - 22
    ) THEN
        RAISE EXCEPTION 'WAD texture definition is outside its catalog' USING ERRCODE = '22023';
    END IF;

    -- The next distinct offset limits each record even when entries are out of order.
    RETURN QUERY
    WITH starts AS (
        SELECT DISTINCT offsets.position FROM unnest(record_offsets) AS offsets(position)
    ), bounds AS (
        SELECT starts.position,
               lead(starts.position, 1, catalog_size) OVER (ORDER BY starts.position) AS end_position
        FROM starts
    )
    SELECT entry.entry_index, upper(doom.wad_name(substring(p_catalog FROM entry.position + 1 FOR 8)) COLLATE "C"),
           entry.position, bounds.end_position
    FROM unnest(record_offsets) WITH ORDINALITY AS entry(position, entry_index)
    JOIN bounds ON bounds.position = entry.position;
END;
$$;

CREATE FUNCTION doom.wad_textures(p_wad bytea, p_names text[])
RETURNS TABLE(name text, width integer, height integer, pixels bytea, coverage bytea)
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
AS $$
DECLARE
    catalog_names constant text[] := ARRAY['PNAMES', 'TEXTURE1', 'TEXTURE2'];
    requested_names text[];
    archive_index jsonb;
    texture_index jsonb;
    reference jsonb;
    lump_size integer;
    catalog_slot integer;
    catalogs bytea[] := ARRAY[NULL::bytea, NULL, NULL];
    patch_name_data bytea;
    patch_name_count integer;
    texture_data bytea;
    texture_offset integer;
    texture_end integer;
    component_count integer;
    component_index integer;
    component_offset integer;
    patch_index integer;
    patch_name text;
    patch record;
    origin_x integer;
    origin_y integer;
    first_x integer;
    last_x integer;
    first_y integer;
    visible_height integer;
    source_x integer;
    source_offset integer;
    target_column integer;
    target_y integer;
    blank_column bytea;
    pixel_columns bytea[];
    coverage_columns bytea[];
    column_pixels bytea;
    column_coverage bytea;
    visible_mask bytea;
    cursor_y integer;
    run_y integer;
    run_size integer;
BEGIN
    IF EXISTS (SELECT FROM unnest(p_names) AS request(label) WHERE label IS NULL OR label = '') THEN
        RAISE EXCEPTION 'WAD texture name is required' USING ERRCODE = '22023';
    END IF;

    SELECT array_agg(label ORDER BY first_position) INTO requested_names
    FROM (
        SELECT upper(request.label COLLATE "C") AS label, min(request.entry_index) AS first_position
        FROM unnest(p_names) WITH ORDINALITY AS request(label, entry_index)
        GROUP BY upper(request.label COLLATE "C")
    ) AS requests;
    IF requested_names IS NULL THEN
        RETURN;
    END IF;

    SELECT jsonb_object_agg(upper(entry.name COLLATE "C"), jsonb_build_array(entry.data_offset, entry.data_size)
                            ORDER BY entry.ordinal)
    INTO archive_index
    FROM doom.wad_directory(p_wad) AS entry;

    FOR catalog_slot IN 1..3 LOOP
        reference := archive_index -> catalog_names[catalog_slot];
        IF catalog_slot = 3 AND reference IS NULL THEN
            CONTINUE;
        END IF;
        lump_size := (reference ->> 1)::integer;
        IF lump_size IS NULL OR lump_size < 4 THEN
            RAISE EXCEPTION 'missing or truncated WAD lump %', catalog_names[catalog_slot] USING ERRCODE = '22023';
        END IF;
        catalogs[catalog_slot] := substring(p_wad FROM (reference ->> 0)::integer + 1 FOR lump_size);
    END LOOP;

    patch_name_data := catalogs[1];
    patch_name_count := doom.wad_i32(patch_name_data, 0);
    IF patch_name_count < 0 OR 4 + 8::bigint * patch_name_count > octet_length(patch_name_data) THEN
        RAISE EXCEPTION 'invalid WAD PNAMES size' USING ERRCODE = '22023';
    END IF;

    SELECT jsonb_object_agg(entry.name, jsonb_build_array(catalog.slot, entry.record_offset, entry.record_end)
                            ORDER BY catalog.slot, entry.ordinal)
    INTO texture_index
    FROM generate_series(2, 3) AS catalog(slot)
    CROSS JOIN LATERAL doom.wad_texture_records(catalogs[catalog.slot]) AS entry
    WHERE entry.name = ANY (requested_names);

    FOREACH name IN ARRAY requested_names LOOP
        reference := texture_index -> name;
        IF reference IS NULL THEN
            RAISE EXCEPTION 'WAD texture % does not exist', name USING ERRCODE = '22023';
        END IF;
        texture_data := catalogs[(reference ->> 0)::integer];
        texture_offset := (reference ->> 1)::integer;
        texture_end := (reference ->> 2)::integer;
        IF texture_end - texture_offset < 22 THEN
            RAISE EXCEPTION 'truncated WAD texture definition %', name USING ERRCODE = '22023';
        END IF;

        width := doom.wad_i16(texture_data, texture_offset + 12);
        height := doom.wad_i16(texture_data, texture_offset + 14);
        component_count := doom.wad_i16(texture_data, texture_offset + 20);
        IF width <= 0 OR height <= 0 OR width * height > 16 * 1024 * 1024 THEN
            RAISE EXCEPTION 'invalid or oversized WAD texture dimensions for %', name USING ERRCODE = '22023';
        END IF;
        IF component_count < 0 OR texture_offset + 22 + 10 * component_count > texture_end THEN
            RAISE EXCEPTION 'invalid WAD texture patch list for %', name USING ERRCODE = '22023';
        END IF;

        blank_column := decode(repeat('00', height), 'hex');
        pixel_columns := array_fill(blank_column, ARRAY[width]);
        coverage_columns := array_fill(blank_column, ARRAY[width]);

        FOR component_index IN 0..(component_count - 1) LOOP
            component_offset := texture_offset + 22 + 10 * component_index;
            origin_x := doom.wad_i16(texture_data, component_offset);
            origin_y := doom.wad_i16(texture_data, component_offset + 2);
            patch_index := doom.wad_u16(texture_data, component_offset + 4);
            IF patch_index >= patch_name_count THEN
                RAISE EXCEPTION 'WAD texture % has an invalid PNAMES index %', name, patch_index USING ERRCODE = '22023';
            END IF;

            patch_name := upper(doom.wad_name(substring(patch_name_data FROM 5 + 8 * patch_index FOR 8)) COLLATE "C");
            reference := archive_index -> patch_name;
            lump_size := (reference ->> 1)::integer;
            IF lump_size IS NULL OR lump_size = 0 THEN
                RAISE EXCEPTION 'WAD patch % is missing for texture %', patch_name, name USING ERRCODE = '22023';
            END IF;
            SELECT * INTO patch
            FROM doom.wad_patch(substring(p_wad FROM (reference ->> 0)::integer + 1 FOR lump_size));

            first_x := greatest(0, -origin_x);
            last_x := least(patch.width, width - origin_x) - 1;
            first_y := greatest(0, -origin_y);
            visible_height := least(patch.height, height - origin_y) - first_y;
            IF visible_height <= 0 THEN
                CONTINUE;
            END IF;

            FOR source_x IN first_x..last_x LOOP
                source_offset := source_x * patch.height + first_y;
                visible_mask := substring(patch.coverage FROM source_offset + 1 FOR visible_height);
                target_column := origin_x + source_x + 1;
                target_y := origin_y + first_y;
                column_pixels := pixel_columns[target_column];
                column_coverage := coverage_columns[target_column];
                cursor_y := 0;

                LOOP
                    run_y := position('\xff'::bytea IN substring(visible_mask FROM cursor_y + 1));
                    EXIT WHEN run_y = 0;
                    run_y := cursor_y + run_y - 1;
                    run_size := coalesce(nullif(position('\x00'::bytea IN substring(visible_mask FROM run_y + 1)), 0) - 1,
                                         visible_height - run_y);
                    column_pixels := overlay(column_pixels
                        PLACING substring(patch.pixels FROM source_offset + run_y + 1 FOR run_size)
                        FROM target_y + run_y + 1 FOR run_size);
                    column_coverage := overlay(column_coverage
                        PLACING substring(visible_mask FROM run_y + 1 FOR run_size)
                        FROM target_y + run_y + 1 FOR run_size);
                    cursor_y := run_y + run_size;
                END LOOP;

                pixel_columns[target_column] := column_pixels;
                coverage_columns[target_column] := column_coverage;
            END LOOP;
        END LOOP;

        SELECT string_agg(columns.pixel_bytes, '\x'::bytea ORDER BY columns.ordinality),
               string_agg(columns.coverage_bytes, '\x'::bytea ORDER BY columns.ordinality)
        INTO pixels, coverage
        FROM unnest(pixel_columns, coverage_columns) WITH ORDINALITY AS columns(pixel_bytes, coverage_bytes);
        RETURN NEXT;
    END LOOP;
END;
$$;
