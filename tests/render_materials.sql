\set ON_ERROR_STOP on
BEGIN;

DO $$
DECLARE
    test_level bigint;
    front_game bigint;
    back_game bigint;
    frame bytea;
    packet bytea;
    decoded bytea;
    sample record;
    observed bytea;
    width integer := 9;
    height integer := 23;
BEGIN
    INSERT INTO doom.levels (name) VALUES ('Indexed material fixture')
    RETURNING level_id INTO test_level;

    INSERT INTO doom.level_palettes (level_id, palette)
    VALUES (test_level, decode('119922336699884422AABBCCC8AA64F0C0800630C044FF88E140503080E0'
        || repeat('00', 738), 'hex'));

    INSERT INTO doom.level_materials (level_id, surface_kind, name, width, height, pixels, coverage)
    VALUES
        (test_level, 'flat', 'FLOOR', 2, 2, '\x01000304', '\xffffffff'),
        (test_level, 'flat', 'CEILING', 2, 2, '\x07080902', '\xffffffff'),
        (test_level, 'flat', 'FARFLOOR', 2, 2, '\x01000308', '\xffffffff'),
        (test_level, 'wall', 'UPPER', 1, 1, '\x07', '\xff'),
        (test_level, 'wall', 'LOWER', 1, 1, '\x08', '\xff'),
        (test_level, 'wall', 'FRONT', 1, 1, '\x03', '\xff'),
        (test_level, 'wall', 'BACK', 3, 1, '\x070809', '\xffffff'),
        (test_level, 'wall', 'FAR', 3, 2, '\x010203040506', '\xffffffffff00');

    INSERT INTO doom.sectors
        (level_id, sector_id, floor_height, ceiling_height, light_level, floor_color, ceiling_color,
         floor_material, ceiling_material)
    VALUES
        (test_level, 0, 0, 96, 255, x'222222'::integer, x'333333'::integer, 'floor', 'CEILING'),
        (test_level, 1, 12, 68, 127, x'444444'::integer, x'555555'::integer, 'FARFLOOR', NULL);

    INSERT INTO doom.lines
        (level_id, line_id, x1, y1, x2, y2, front_sector_id, back_sector_id, wall_color)
    VALUES
        (test_level, 0, 32, 64, 32, -64, 0, 1, x'D0A010'::integer),
        (test_level, 1, 96, 64, 96, -64, 1, NULL, x'406080'::integer);

    INSERT INTO doom.line_surfaces
        (level_id, line_id, is_back, x_offset, y_offset, upper_material, lower_material, middle_material)
    VALUES
        (test_level, 0, false, 0, 0, 'UPPER', 'LOWER', 'FRONT'),
        (test_level, 0, true, -64, 0, NULL, NULL, 'BACK'),
        (test_level, 1, false, -69, -27, NULL, NULL, 'far');

    front_game := doom.start_game(test_level, 0, 0, -1);
    frame := doom.render(front_game, width, height);

    -- The middle column looks due east from y = -1. At rows 0 and 22 the
    -- plane hits have even x. The rightmost ray hits floor y = -15.91.
    -- The rear wall's middle column wraps u = 65 - 69 to column 2 of 3.
    -- Rows 11 and 12 cross wall v = 0 and v = 21.33, respectively.
    -- Row 14 hits the farther floor at (43.5, -1), between the two walls.
    FOR sample IN SELECT * FROM (VALUES
        (4,  6, '44FF88', 'portal upper band'),
        (4, 16, 'E14050', 'portal lower band'),
        (4, 11, '786040', 'wrapped and shaded wall texel'),
        (4, 12, '203040', 'masked wall texel fallback'),
        (4, 14, '702028', 'far sector floor and light through portal'),
        (4,  0, 'E14050', 'world-aligned ceiling'),
        (4, 22, '119922', 'opaque palette index zero on floor'),
        (8, 22, '336699', 'off-axis floor projection')
    ) AS expected(x, y, rgb, behavior)
    LOOP
        observed := substring(frame FROM (sample.y * width + sample.x) * 3 + 1 FOR 3);
        IF observed IS DISTINCT FROM decode(sample.rgb, 'hex') THEN
            RAISE EXCEPTION '% at (%, %), expected %, got %',
                sample.behavior, sample.x, sample.y, sample.rgb, encode(observed, 'hex');
        END IF;
    END LOOP;

    -- The back side measures u from the opposite endpoint. Its u = 63 - 64
    -- wraps to column 2, then the viewing sector's light shades palette index 9.
    back_game := doom.start_game(test_level, 1, 64, -1, pi());
    INSERT INTO doom.sector_state (game_id, level_id, sector_id, floor_height, ceiling_height)
    VALUES (back_game, test_level, 0, 0, 0);
    IF doom.render(back_game, 1, 1) IS DISTINCT FROM '\x184070'::bytea
        OR doom.render_spans(back_game, 1, 1) IS DISTINCT FROM '\x00000000184070'::bytea
    THEN
        RAISE EXCEPTION 'The back side of a closed portal must use its own material, origin and light';
    END IF;

    INSERT INTO doom.actor_types (kind, default_health, radius, height, color)
    VALUES ('material-fixture-mote', 5, 5, 64, x'00E0E0'::integer);
    INSERT INTO doom.actors (game_id, sector_id, kind, x, y)
    VALUES (front_game, 1, 'material-fixture-mote', 60, -1);

    frame := doom.render(front_game, width, height);
    IF substring(frame FROM (11 * width + 4) * 3 + 1 FOR 3) IS DISTINCT FROM '\x007070'::bytea THEN
        RAISE EXCEPTION 'A nearer actor must occlude the textured rear wall';
    END IF;

    packet := doom.render_spans(front_game, width, height);
    WITH changes AS MATERIALIZED (
        SELECT get_byte(packet, pos) * 256 + get_byte(packet, pos + 1) AS y,
               get_byte(packet, pos + 2) * 256 + get_byte(packet, pos + 3) AS x,
               substring(packet FROM pos + 5 FOR 3) AS rgb
        FROM generate_series(0, octet_length(packet) - 1, 7) AS pos
    )
    SELECT string_agg(pixel.rgb, ''::bytea ORDER BY py, px)
    INTO decoded
    FROM generate_series(0, height - 1) AS py
    CROSS JOIN generate_series(0, width - 1) AS px
    CROSS JOIN LATERAL (
        SELECT rgb FROM changes WHERE x = px AND y <= py ORDER BY y DESC LIMIT 1
    ) AS pixel;

    IF decoded IS DISTINCT FROM frame THEN
        RAISE EXCEPTION 'Compact frame must reconstruct the textured scene with actor occlusion';
    END IF;

    DELETE FROM doom.level_materials
    WHERE level_id = test_level AND surface_kind = 'wall' AND name = 'UPPER';
    frame := doom.render(front_game, width, height);
    IF substring(frame FROM (6 * width + 4) * 3 + 1 FOR 3) IS DISTINCT FROM '\xd0a010'::bytea THEN
        RAISE EXCEPTION 'A missing material must preserve the solid surface color';
    END IF;

    DELETE FROM doom.level_palettes WHERE level_id = test_level;
    frame := doom.render(front_game, width, height);
    IF substring(frame FROM (16 * width + 4) * 3 + 1 FOR 3) IS DISTINCT FROM '\xd0a010'::bytea
        OR substring(frame FROM (22 * width + 4) * 3 + 1 FOR 3) IS DISTINCT FROM '\x222222'::bytea
    THEN
        RAISE EXCEPTION 'A missing palette must preserve the solid surface colors';
    END IF;
END;
$$;

ROLLBACK;
