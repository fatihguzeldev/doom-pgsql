\set ON_ERROR_STOP on
BEGIN;

DO $$
DECLARE
    first_level bigint;
    second_level bigint;
    first_game bigint;
    second_game bigint;
    tail bytea;
    first_palette bytea;
    second_palette bytea;
    shade_bytes bytea;
    shade record;
BEGIN
    INSERT INTO doom.levels (name) VALUES ('First palette fixture') RETURNING level_id INTO first_level;
    INSERT INTO doom.levels (name) VALUES ('Second palette fixture') RETURNING level_id INTO second_level;

    SELECT decode(string_agg(lpad(to_hex((channel * 73 + 17) % 256), 2, '0'), '' ORDER BY channel), 'hex')
    INTO tail
    FROM generate_series(9, 767) AS channel;
    first_palette := '\x000102017ffffe8001'::bytea || tail;
    second_palette := '\x00010240820fff4002'::bytea || tail;
    INSERT INTO doom.level_palettes (level_id, palette)
    VALUES (first_level, first_palette), (second_level, second_palette);

    SELECT level_palette.shade_bytes INTO shade_bytes
    FROM doom.level_palettes AS level_palette WHERE level_id = first_level;
    IF octet_length(shade_bytes) IS DISTINCT FROM 256 * 768 THEN
        RAISE EXCEPTION 'A palette must have one complete shade for every light level';
    END IF;

    FOR shade IN
        SELECT light, decode(string_agg(lpad(to_hex(
            round(get_byte(first_palette, channel) * light / 255.0)::integer
        ), 2, '0'), '' ORDER BY channel), 'hex') AS expected
        FROM unnest(ARRAY[0, 1, 63, 127, 128, 254, 255]) AS light
        CROSS JOIN generate_series(0, 767) AS channel
        GROUP BY light
    LOOP
        IF substring(shade_bytes FROM shade.light * 768 + 1 FOR 768) IS DISTINCT FROM shade.expected THEN
            RAISE EXCEPTION 'Incorrect palette shade at light level %', shade.light;
        END IF;
    END LOOP;

    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height, light_level)
    SELECT level_id, 0, 0, 96, 127 FROM unnest(ARRAY[first_level, second_level]) AS level_id;
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id, wall_color)
    SELECT level_id, 0, 32, 64, 32, -64, 0, x'204060'::integer
    FROM unnest(ARRAY[first_level, second_level]) AS level_id;
    INSERT INTO doom.line_surfaces (level_id, line_id, is_back, middle_material)
    SELECT level_id, 0, false, 'SWATCH' FROM unnest(ARRAY[first_level, second_level]) AS level_id;
    INSERT INTO doom.level_materials (level_id, surface_kind, name, width, height, pixels, coverage)
    SELECT level_id, 'wall', 'SWATCH', 1, 1, '\x01'::bytea, '\xff'::bytea
    FROM unnest(ARRAY[first_level, second_level]) AS level_id;
    first_game := doom.start_game(first_level, 0, 0, 0);
    second_game := doom.start_game(second_level, 0, 0, 0);

    IF doom.render(first_game, 1, 1) IS DISTINCT FROM '\x003f7f'::bytea
        OR doom.render_spans(first_game, 1, 1) IS DISTINCT FROM '\x00000000003f7f'::bytea
        OR doom.render(second_game, 1, 1) IS DISTINCT FROM '\x204107'::bytea
    THEN
        RAISE EXCEPTION 'The RGB and span samplers must use the current level palette';
    END IF;

    BEGIN
        UPDATE doom.level_palettes SET palette = second_palette WHERE level_id = first_level;
        IF (SELECT substring(level_palette.shade_bytes FROM 127 * 768 + 4 FOR 3)
            FROM doom.level_palettes AS level_palette WHERE level_id = first_level) IS DISTINCT FROM '\x204107'::bytea
            OR doom.render(first_game, 1, 1) IS DISTINCT FROM '\x204107'::bytea
        THEN
            RAISE EXCEPTION 'A direct palette update must refresh the shaded color';
        END IF;
        RAISE SQLSTATE 'ZX001';
    EXCEPTION WHEN SQLSTATE 'ZX001' THEN
        NULL;
    END;
    IF doom.render(first_game, 1, 1) IS DISTINCT FROM '\x003f7f'::bytea THEN
        RAISE EXCEPTION 'Rolling back a palette update must restore the cached shade';
    END IF;

    BEGIN
        UPDATE doom.level_palettes SET palette = '\x00'::bytea WHERE level_id = first_level;
        RAISE EXCEPTION 'A short palette must fail length validation';
    EXCEPTION WHEN check_violation THEN
        NULL;
    END;

    INSERT INTO doom.level_palettes (level_id, palette)
    VALUES (first_level, overlay(first_palette PLACING '\x020080'::bytea FROM 4 FOR 3))
    ON CONFLICT (level_id) DO UPDATE SET palette = excluded.palette;
    IF doom.render(first_game, 1, 1) IS DISTINCT FROM '\x010040'::bytea
        OR doom.render(second_game, 1, 1) IS DISTINCT FROM '\x204107'::bytea
    THEN
        RAISE EXCEPTION 'A palette upsert must replace shades for only the target level';
    END IF;

    INSERT INTO doom.level_materials
        (level_id, surface_kind, name, width, height, left_offset, top_offset, pixels, coverage)
    VALUES (first_level, 'sprite', 'FLAKE', 2, 2, 1, 2, '\x02020202', '\xffffffff');
    INSERT INTO doom.actor_types (kind, default_health, radius, height, sprite_material)
    VALUES ('palette-fixture-flake', 1, 0, 16, 'FLAKE');
    INSERT INTO doom.actors (game_id, sector_id, kind, x, y, z)
    VALUES (first_game, 0, 'palette-fixture-flake', 16, 0, 40);
    IF doom.render(first_game, 1, 1) IS DISTINCT FROM '\x7f4000'::bytea THEN
        RAISE EXCEPTION 'A foreground sprite must sample the current shaded palette';
    END IF;

    UPDATE doom.sectors SET light_level = 128 WHERE level_id = first_level AND sector_id = 0;
    IF doom.render_spans(first_game, 1, 1) IS DISTINCT FROM '\x000000007f4001'::bytea THEN
        RAISE EXCEPTION 'A sector light edit must change sprite rounding at the 127 to 128 boundary';
    END IF;

    UPDATE doom.sectors SET light_level = 255 WHERE level_id = first_level AND sector_id = 0;
    IF doom.render(first_game, 1, 1) IS DISTINCT FROM '\xfe8001'::bytea THEN
        RAISE EXCEPTION 'Full light must preserve the original palette bytes';
    END IF;

    DELETE FROM doom.level_palettes WHERE level_id = first_level;
    IF doom.render(first_game, 1, 1) IS DISTINCT FROM '\x204060'::bytea
        OR doom.render(second_game, 1, 1) IS DISTINCT FROM '\x204107'::bytea
    THEN
        RAISE EXCEPTION 'Deleting one palette must restore solid fallback for only its level';
    END IF;
END;
$$;

ROLLBACK;
