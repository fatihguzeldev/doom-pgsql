\set ON_ERROR_STOP on
BEGIN;

DO $$
DECLARE
    test_level bigint;
    front_game bigint;
    back_game bigint;
    test_actor bigint;
    width integer := 16;
    height integer := 60;
    frame bytea;
    packet bytea;
    decoded bytea;
    observed bytea;
    sample record;
BEGIN
    INSERT INTO doom.levels (name) VALUES ('Masked portal fixture')
    RETURNING level_id INTO test_level;

    INSERT INTO doom.level_palettes (level_id, palette)
    VALUES (test_level, decode('D04020EEAA30AA55EE20B04009D0E0AA000000AA000000AA'
        || repeat('00', 744), 'hex'));

    INSERT INTO doom.level_materials (level_id, surface_kind, name, width, height, pixels, coverage)
    VALUES
        (test_level, 'wall', 'NEARMASK', 3, 4, '\x000101000101010102020202', '\xff00ff00ffffffffffffffff'),
        (test_level, 'wall', 'FARMASK', 1, 8, '\x0003000400050000', '\x00ff000100ff0000'),
        (test_level, 'wall', 'BACKMASK', 3, 4, '\x050505050606060607070707', '\xffffffffffffffffffffffff');

    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height, light_level)
    VALUES (test_level, 0, 0, 80, 255), (test_level, 1, 0, 80, 255), (test_level, 2, 0, 80, 255);

    INSERT INTO doom.lines
        (level_id, line_id, x1, y1, x2, y2, front_sector_id, back_sector_id, wall_color)
    VALUES
        (test_level, 0,  8,  64,  8, -64, 0, 1, x'777777'::integer),
        (test_level, 1, 16,  64, 16, -64, 1, 2, x'666666'::integer),
        (test_level, 2, 24,  64, 24, -64, 2, NULL, x'8899AA'::integer),
        (test_level, 3, -8, -64, -8,  64, 0, NULL, x'506070'::integer),
        (test_level, 4, 32,  64, 32, -64, 0, NULL, x'306090'::integer);

    INSERT INTO doom.line_surfaces (level_id, line_id, is_back, x_offset, y_offset, middle_material)
    VALUES
        (test_level, 0, false, -67, -37, 'nEaRmAsK'),
        (test_level, 0, true, -68, -38, 'BACKMASK'),
        (test_level, 1, false, 0, -35, 'FARMASK');

    front_game := doom.start_game(test_level, 0, 0, -0.25);
    frame := doom.render(front_game, width, height);
    IF octet_length(frame) IS DISTINCT FROM width * height * 3 THEN
        RAISE EXCEPTION 'Masked scene must cover the complete RGB frame';
    END IF;

    -- At x = 8 the front ray has u = 64.75 - 67, wrapping to texel column 0.
    -- The adjacent ray wraps to column 2. Row 28 samples v = 0.5 at the near
    -- opening and v = 1 at the far opening. Each next row adds 1 and 2 respectively.
    FOR sample IN SELECT * FROM (VALUES
        (8, 27, '8899AA', 'negative v reveals the rear wall'),
        (8, 28, 'D04020', 'near opaque index zero covers the far mask'),
        (8, 29, '09D0E0', 'near hole reveals coverage byte one on far mask'),
        (8, 30, 'EEAA30', 'near mask occludes a second opaque far texel'),
        (8, 31, '8899AA', 'holes in both masks reveal the rear wall'),
        (8, 32, '8899AA', 'mask height ends without vertical repeat'),
        (7, 28, 'AA55EE', 'adjacent ray selects another wrapped column')
    ) AS expected(x, y, rgb, behavior)
    LOOP
        observed := substring(frame FROM (sample.y * width + sample.x) * 3 + 1 FOR 3);
        IF observed IS DISTINCT FROM decode(sample.rgb, 'hex') THEN
            RAISE EXCEPTION '% at (%, %), expected %, got %',
                sample.behavior, sample.x, sample.y, sample.rgb, encode(observed, 'hex');
        END IF;
    END LOOP;

    back_game := doom.start_game(test_level, 1, 16, -0.25, pi());
    frame := doom.render(back_game, width, height);
    -- The reverse ray measures from y = -64, so u = 64.25 - 68 wraps
    -- to column 2. Its vertical offset starts the visible pane at row 29.
    IF substring(frame FROM (28 * width + 8) * 3 + 1 FOR 3) IS DISTINCT FROM '\x506070'::bytea
        OR substring(frame FROM (29 * width + 8) * 3 + 1 FOR 3) IS DISTINCT FROM '\x0000aa'::bytea
    THEN
        RAISE EXCEPTION 'The open back face must use its own material and offsets';
    END IF;

    INSERT INTO doom.actor_types (kind, default_health, radius, height, color)
    VALUES ('mask-fixture-orb', 5, 2, 70, x'F0E0D0'::integer);
    INSERT INTO doom.actors (game_id, sector_id, kind, x, y)
    VALUES (front_game, 2, 'mask-fixture-orb', 20, -1.5) RETURNING actor_id INTO test_actor;

    frame := doom.render(front_game, width, height);
    IF substring(frame FROM (28 * width + 8) * 3 + 1 FOR 3) IS DISTINCT FROM '\xd04020'::bytea
        OR substring(frame FROM (29 * width + 8) * 3 + 1 FOR 3) IS DISTINCT FROM '\x09d0e0'::bytea
        OR substring(frame FROM (31 * width + 8) * 3 + 1 FOR 3) IS DISTINCT FROM '\xf0e0d0'::bytea
    THEN
        RAISE EXCEPTION 'Both masks must occlude a rear actor while their holes reveal it';
    END IF;

    UPDATE doom.actors SET sector_id = 1, x = 12, y = -1
    WHERE game_id = front_game AND actor_id = test_actor;
    frame := doom.render(front_game, width, height);
    IF substring(frame FROM (28 * width + 8) * 3 + 1 FOR 3) IS DISTINCT FROM '\xd04020'::bytea
        OR substring(frame FROM (29 * width + 8) * 3 + 1 FOR 3) IS DISTINCT FROM '\xf0e0d0'::bytea
    THEN
        RAISE EXCEPTION 'An actor between masks must cover only the farther pane';
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
        RAISE EXCEPTION 'Compact output must reconstruct the masked scene and actor exactly';
    END IF;

    UPDATE doom.actors SET sector_id = 0, x = 4, y = -0.5
    WHERE game_id = front_game AND actor_id = test_actor;
    frame := doom.render(front_game, width, height);
    IF substring(frame FROM (28 * width + 8) * 3 + 1 FOR 3) IS DISTINCT FROM '\xf0e0d0'::bytea
        OR substring(frame FROM (29 * width + 8) * 3 + 1 FOR 3) IS DISTINCT FROM '\xf0e0d0'::bytea
    THEN
        RAISE EXCEPTION 'A foreground actor must cover both panes';
    END IF;

    DELETE FROM doom.actors WHERE game_id = front_game AND actor_id = test_actor;

    INSERT INTO doom.sector_state (game_id, level_id, sector_id, floor_height, ceiling_height)
    VALUES (front_game, test_level, 1, 41, 42);
    UPDATE doom.line_surfaces SET y_offset = 1
    WHERE level_id = test_level AND line_id = 0 AND NOT is_back;
    frame := doom.render(front_game, width, height);
    -- All three rows sample opaque texels on column 2. The narrowed opening
    -- admits only row 29, leaving the upper and lower wall bands in place.
    IF substring(frame FROM (28 * width + 7) * 3 + 1 FOR 3) IS DISTINCT FROM '\x777777'::bytea
        OR substring(frame FROM (29 * width + 7) * 3 + 1 FOR 3) IS DISTINCT FROM '\xaa55ee'::bytea
        OR substring(frame FROM (30 * width + 7) * 3 + 1 FOR 3) IS DISTINCT FROM '\x777777'::bytea
    THEN
        RAISE EXCEPTION 'Mask coverage must stay inside the current portal opening';
    END IF;
    DELETE FROM doom.sector_state WHERE game_id = front_game AND sector_id = 1;
    UPDATE doom.line_surfaces SET y_offset = -37
    WHERE level_id = test_level AND line_id = 0 AND NOT is_back;

    UPDATE doom.lines SET back_sector_id = 0 WHERE level_id = test_level AND line_id = 0;
    UPDATE doom.actors SET sector_id = 0 WHERE game_id = back_game AND kind = 'player';
    frame := doom.render(front_game, width, height);
    IF substring(frame FROM (28 * width + 8) * 3 + 1 FOR 3) IS DISTINCT FROM '\xd04020'::bytea
        OR substring(frame FROM (29 * width + 8) * 3 + 1 FOR 3) IS DISTINCT FROM '\x306090'::bytea
    THEN
        RAISE EXCEPTION 'A same-sector screen must reveal the original sector through a hole';
    END IF;
    frame := doom.render(back_game, width, height);
    IF substring(frame FROM (29 * width + 8) * 3 + 1 FOR 3) IS DISTINCT FROM '\x0000aa'::bytea THEN
        RAISE EXCEPTION 'A same-sector screen must use the facing back binding';
    END IF;
    UPDATE doom.line_surfaces SET middle_material = NULL
    WHERE level_id = test_level AND line_id = 0 AND is_back;
    frame := doom.render(back_game, width, height);
    IF substring(frame FROM (29 * width + 8) * 3 + 1 FOR 3) IS DISTINCT FROM '\x506070'::bytea THEN
        RAISE EXCEPTION 'An unbound back face must leave the same-sector screen transparent';
    END IF;
    UPDATE doom.lines SET back_sector_id = 1 WHERE level_id = test_level AND line_id = 0;

    DELETE FROM doom.level_materials
    WHERE level_id = test_level AND surface_kind = 'wall' AND name = 'NEARMASK';
    frame := doom.render(front_game, width, height);
    IF substring(frame FROM (28 * width + 8) * 3 + 1 FOR 3) IS DISTINCT FROM '\x20b040'::bytea THEN
        RAISE EXCEPTION 'A missing near material must reveal a farther masked material';
    END IF;

    DELETE FROM doom.level_materials
    WHERE level_id = test_level AND surface_kind = 'wall' AND name = 'FARMASK';
    frame := doom.render(front_game, width, height);
    IF substring(frame FROM (28 * width + 8) * 3 + 1 FOR 3) IS DISTINCT FROM '\x8899aa'::bytea THEN
        RAISE EXCEPTION 'Missing mask materials must leave a portal open to the rear wall';
    END IF;
END;
$$;

ROLLBACK;
