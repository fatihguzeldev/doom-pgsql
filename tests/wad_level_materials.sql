BEGIN;

CREATE FUNCTION pg_temp.level_material_le32(p_value integer)
RETURNS bytea LANGUAGE sql IMMUTABLE STRICT
RETURN decode(lpad(to_hex(p_value & 255), 2, '0')
    || lpad(to_hex((p_value >> 8) & 255), 2, '0')
    || lpad(to_hex((p_value >> 16) & 255), 2, '0')
    || lpad(to_hex((p_value >> 24) & 255), 2, '0'), 'hex');

CREATE FUNCTION pg_temp.level_material_archive(p_names text[], p_data bytea[])
RETURNS bytea LANGUAGE sql IMMUTABLE STRICT
RETURN (
    WITH entries AS (
        SELECT name, payload, entry_index, octet_length(payload) AS size,
               12 + coalesce(sum(octet_length(payload)) OVER (
                   ORDER BY entry_index ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0)::integer AS position
        FROM unnest(p_names, p_data) WITH ORDINALITY AS entry(name, payload, entry_index)
    )
    SELECT '\x50574144'::bytea || pg_temp.level_material_le32(count(*)::integer)
        || pg_temp.level_material_le32(12 + sum(size)::integer)
        || string_agg(payload, '\x'::bytea ORDER BY entry_index)
        || string_agg(pg_temp.level_material_le32(position) || pg_temp.level_material_le32(size)
             || convert_to(name, 'UTF8') || decode(repeat('00', 8 - length(name)), 'hex'),
             '\x'::bytea ORDER BY entry_index)
    FROM entries
);

DO $$
DECLARE
    main_palette bytea := decode(repeat('123456', 256), 'hex');
    other_palette bytea := decode(repeat('aabbcc', 256), 'hex');
    wall_patch bytea := decode('0200 0100 0000 0000 10000000 16000000 0001000700ff ff', 'hex');
    texture_catalog bytea := decode(
        '01000000 08000000 50414e454c000000 00000000 0200 0100 00000000 0100' ||
        '0000 0000 0000 0000 0000', 'hex');
    pnames bytea := '\x010000005041544348000000';
    collision bytea := decode(repeat('ee', 4096), 'hex');
    flat_bytes bytea;
    archive bytea;
    main_level bigint;
    second_level bigint;
    test_game bigint;
    palette_tuple tid;
    observed record;
BEGIN
    SELECT decode(string_agg(lpad(to_hex((sample % 64 + 3 * (sample / 64)) % 256), 2, '0'), ''
                             ORDER BY sample), 'hex')
    INTO flat_bytes
    FROM generate_series(0, 4095) AS samples(sample);

    archive := pg_temp.level_material_archive(
        ARRAY['PLAYPAL', 'TEXTURE1', 'PATCH', 'F_START', 'FLOOR_A', 'F_END', 'floor_a', 'playpal', 'PNAMES'],
        ARRAY['\x00'::bytea, texture_catalog, wall_patch, '\x', flat_bytes, '\x', collision,
              main_palette || other_palette, pnames]);

    INSERT INTO doom.levels (name) VALUES ('material test') RETURNING level_id INTO main_level;
    INSERT INTO doom.levels (name) VALUES ('palette only') RETURNING level_id INTO second_level;
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height, floor_material, ceiling_material)
    VALUES (main_level, 0, 0, 128, 'FLOOR_A', 'FLOOR_A');
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id)
    VALUES (main_level, 0, 0, 0, 64, 0, 0);
    INSERT INTO doom.line_surfaces (level_id, line_id, is_back, middle_material, upper_material)
    VALUES (main_level, 0, false, 'PANEL', 'PANEL');

    PERFORM doom.import_wad_materials(main_level, archive);
    IF (SELECT palette FROM doom.level_palettes WHERE level_id = main_level) IS DISTINCT FROM main_palette THEN
        RAISE EXCEPTION 'incorrect initial PLAYPAL for level';
    END IF;
    IF (SELECT count(*) FROM doom.level_materials WHERE level_id = main_level) <> 2 THEN
        RAISE EXCEPTION 'expected one distinct material of each kind';
    END IF;

    SELECT ctid INTO STRICT palette_tuple FROM doom.level_palettes WHERE level_id = main_level;
    UPDATE doom.level_materials SET pixels = '\x0000'
    WHERE level_id = main_level AND surface_kind = 'wall' AND name = 'PANEL';
    PERFORM doom.import_wad_materials(main_level, archive);
    IF (SELECT ctid FROM doom.level_palettes WHERE level_id = main_level) IS DISTINCT FROM palette_tuple THEN
        RAISE EXCEPTION 'reimport with the same palette should reuse its stored shades';
    END IF;

    SELECT width, height, pixels, coverage INTO observed FROM doom.level_materials
    WHERE level_id = main_level AND surface_kind = 'wall' AND name = 'PANEL';
    IF ROW(observed.width, observed.height, observed.pixels, observed.coverage)
        IS DISTINCT FROM ROW(2, 1, '\x0700'::bytea, '\xff00'::bytea)
    THEN
        RAISE EXCEPTION 'incorrect imported wall material: %', observed;
    END IF;

    SELECT width, height, pixels, coverage INTO observed FROM doom.level_materials
    WHERE level_id = main_level AND surface_kind = 'flat' AND name = 'FLOOR_A';
    IF observed.width IS DISTINCT FROM 64 OR observed.height IS DISTINCT FROM 64
        OR substring(observed.pixels FOR 4) IS DISTINCT FROM '\x00030609'::bytea
        OR substring(observed.pixels FROM 65 FOR 4) IS DISTINCT FROM '\x0104070a'::bytea
        OR get_byte(observed.pixels, 19 * 64 + 37) IS DISTINCT FROM 130
        OR observed.coverage IS DISTINCT FROM decode(repeat('ff', 4096), 'hex')
    THEN
        RAISE EXCEPTION 'incorrect imported flat material';
    END IF;

    test_game := doom.start_game(main_level, 0, 32, -32, pi() / 2);
    IF doom.render(test_game, 1, 1) IS DISTINCT FROM '\x0b2136'::bytea
        OR doom.render_spans(test_game, 1, 1) IS DISTINCT FROM '\x000000000b2136'::bytea
    THEN
        RAISE EXCEPTION 'imported wall palette and texture did not reach both frame formats';
    END IF;

    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height, light_level)
    VALUES (main_level, 1, 0, 128, 255);
    UPDATE doom.lines SET back_sector_id = 1 WHERE level_id = main_level AND line_id = 0;
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id, wall_color)
    VALUES (main_level, 1, 0, 32, 64, 32, 1, 1122867);
    UPDATE doom.line_surfaces SET y_offset = -87 WHERE level_id = main_level AND line_id = 0;

    IF doom.render(test_game, 1, 1) IS DISTINCT FROM '\x0b2136'::bytea THEN
        RAISE EXCEPTION 'opaque imported portal texel did not cover the rear wall';
    END IF;
    UPDATE doom.actors SET x = 33 WHERE game_id = test_game AND kind = 'player';
    IF doom.render(test_game, 1, 1) IS DISTINCT FROM '\x112233'::bytea
        OR doom.render_spans(test_game, 1, 1) IS DISTINCT FROM '\x00000000112233'::bytea
    THEN
        RAISE EXCEPTION 'transparent imported portal texel did not reveal the rear wall';
    END IF;

    PERFORM doom.import_wad_materials(second_level,
        pg_temp.level_material_archive(ARRAY['PLAYPAL'], ARRAY[other_palette]));
    IF (SELECT palette FROM doom.level_palettes WHERE level_id = second_level) IS DISTINCT FROM other_palette
        OR EXISTS (SELECT FROM doom.level_materials WHERE level_id = second_level)
    THEN
        RAISE EXCEPTION 'palette-only imported level should need no texture catalog';
    END IF;

    BEGIN
        PERFORM doom.import_wad_materials(main_level, pg_temp.level_material_archive(
            ARRAY['PLAYPAL', 'TEXTURE1', 'PATCH', 'FLOOR_A', 'PNAMES'],
            ARRAY[other_palette, texture_catalog, wall_patch, substring(flat_bytes FOR 4095), pnames]));
        RAISE EXCEPTION 'material import accepted a short flat';
    EXCEPTION WHEN invalid_parameter_value THEN
        NULL;
    END;
    IF (SELECT palette FROM doom.level_palettes WHERE level_id = main_level) IS DISTINCT FROM main_palette
        OR (SELECT pixels FROM doom.level_materials
            WHERE level_id = main_level AND surface_kind = 'wall' AND name = 'PANEL') IS DISTINCT FROM '\x0700'::bytea
        OR (SELECT get_byte(pixels, 0) FROM doom.level_materials
            WHERE level_id = main_level AND surface_kind = 'flat' AND name = 'FLOOR_A') IS DISTINCT FROM 0
    THEN
        RAISE EXCEPTION 'failed import should preserve existing palette and materials';
    END IF;

    UPDATE doom.line_surfaces SET upper_material = NULL, middle_material = NULL WHERE level_id = main_level;
    PERFORM doom.import_wad_materials(main_level,
        pg_temp.level_material_archive(ARRAY['PLAYPAL', 'FLOOR_A'], ARRAY[other_palette, collision]));
    IF (SELECT palette FROM doom.level_palettes WHERE level_id = main_level) IS DISTINCT FROM other_palette
        OR (SELECT count(*) FROM doom.level_materials WHERE level_id = main_level) <> 1
        OR (SELECT pixels FROM doom.level_materials WHERE level_id = main_level) IS DISTINCT FROM collision
    THEN
        RAISE EXCEPTION 'reimport should replace material rows and remove unused wall textures';
    END IF;
END;
$$;

ROLLBACK;
