\set ON_ERROR_STOP on
BEGIN;

CREATE FUNCTION pg_temp.sprite_pixel(p_frame bytea, p_width integer, p_x integer, p_y integer)
RETURNS bytea
LANGUAGE sql IMMUTABLE STRICT
RETURN substring(p_frame FROM (p_y * p_width + p_x) * 3 + 1 FOR 3);

DO $$
DECLARE
    test_level bigint;
    test_game bigint;
    rear_actor bigint;
    front_actor bigint;
    width constant integer := 32;
    height constant integer := 40;
    frame bytea;
    packet bytea;
    decoded bytea;
    observed bytea;
    sample record;
BEGIN
    INSERT INTO doom.levels (name) VALUES ('Billboard sprite fixture')
    RETURNING level_id INTO test_level;
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height, light_level)
    VALUES (test_level, 0, 0, 80, 255), (test_level, 1, 0, 80, 128), (test_level, 2, 0, 80, 255);
    INSERT INTO doom.lines
        (level_id, line_id, x1, y1, x2, y2, front_sector_id, back_sector_id, wall_color)
    VALUES
        (test_level, 0, 8, 64, 8, -64, 0, 1, x'556677'::integer),
        (test_level, 1, 24, 64, 24, -64, 1, NULL, x'204060'::integer);

    INSERT INTO doom.level_palettes (level_id, palette)
    VALUES (test_level, decode('D0402020A0E012345680E040D060F0E08040E02080' || repeat('00', 747), 'hex'));
    INSERT INTO doom.level_materials
        (level_id, surface_kind, name, width, height, left_offset, top_offset, pixels, coverage)
    VALUES
        (test_level, 'sprite', 'TESTCARD', 3, 3, 1, 2, '\x000102030204040001', '\xff0100ff00ffffffff'),
        (test_level, 'sprite', 'LOWSIGN', 1, 1, -1, -1, '\x06', '\xff'),
        (test_level, 'wall', 'TESTCARD', 1, 1, 0, 0, '\x05', '\xff'),
        (test_level, 'wall', 'FRONTWEB', 1, 2, 0, 0, '\x0505', '\xff00');
    INSERT INTO doom.actor_types (kind, default_health, radius, height, color, sprite_material, dead_sprite_material)
    VALUES ('sprite-fixture-sign', 5, 0, 80, x'22CC66'::integer, 'tEsTcArD', 'LOWSIGN');

    test_game := doom.start_game(test_level, 0, 0, 0);
    INSERT INTO doom.actors (game_id, sector_id, kind, x, y, z)
    VALUES (test_game, 1, 'sprite-fixture-sign', 16, 0, 40)
    RETURNING actor_id INTO rear_actor;

    -- At depth 16 the camera projects one world unit per pixel. The pivot
    -- puts the left edge at -1 and the top at z=42. Columns 15..17 and rows
    -- 19..21 therefore sample the centers of the three columns and rows.
    frame := doom.render(test_game, width, height);
    FOR sample IN SELECT * FROM (VALUES
        (15, 19, '682010', 'palette index zero is opaque and uses the actor sector light'),
        (15, 20, '105070', 'a nonzero coverage byte is opaque'),
        (15, 21, '102030', 'a transparent texel reveals the rear wall'),
        (16, 19, '407020', 'horizontal projection selects the center sprite column'),
        (16, 20, '102030', 'a transparent center texel keeps the rear wall'),
        (16, 21, '683078', 'the bottom sprite row is visible'),
        (17, 20, '682010', 'the rightmost sprite column is visible'),
        (14, 19, '102030', 'the texture does not repeat left of its width'),
        (18, 19, '102030', 'the texture does not repeat right of its width'),
        (16, 18, '102030', 'the top pivot constrains the covered rows'),
        (16, 22, '102030', 'the texture does not repeat below its height')
    ) AS expected(x, y, rgb, behavior)
    LOOP
        observed := pg_temp.sprite_pixel(frame, width, sample.x, sample.y);
        IF observed IS DISTINCT FROM decode(sample.rgb, 'hex') THEN
            RAISE EXCEPTION '% at (%, %), expected %, got %',
                sample.behavior, sample.x, sample.y, sample.rgb, encode(observed, 'hex');
        END IF;
    END LOOP;

    INSERT INTO doom.line_surfaces (level_id, line_id, is_back, y_offset, middle_material)
    VALUES (test_level, 0, false, -38, 'FRONTWEB');
    frame := doom.render(test_game, width, height);
    IF pg_temp.sprite_pixel(frame, width, 15, 19) IS DISTINCT FROM '\xe08040'::bytea
        OR pg_temp.sprite_pixel(frame, width, 15, 20) IS DISTINCT FROM '\x105070'::bytea
    THEN
        RAISE EXCEPTION 'A foreground portal mask must cover the rear sprite only at opaque texels';
    END IF;

    INSERT INTO doom.actors (game_id, sector_id, kind, x, y, z)
    VALUES (test_game, 0, 'sprite-fixture-sign', 4, 0, 40)
    RETURNING actor_id INTO front_actor;
    frame := doom.render(test_game, width, height);
    IF pg_temp.sprite_pixel(frame, width, 16, 19) IS DISTINCT FROM '\x80e040'::bytea
        OR pg_temp.sprite_pixel(frame, width, 17, 20) IS DISTINCT FROM '\x682010'::bytea
    THEN
        RAISE EXCEPTION 'Near sprite texels must cover the mask and sprite holes must reveal a farther sprite';
    END IF;

    packet := doom.render_spans(test_game, width, height);
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
        RAISE EXCEPTION 'Compact output must reconstruct both depth-composed sprites exactly';
    END IF;

    DELETE FROM doom.actors WHERE game_id = test_game AND actor_id = front_actor;
    DELETE FROM doom.line_surfaces WHERE level_id = test_level AND line_id = 0;
    UPDATE doom.actors SET x = 32, sector_id = 2 WHERE game_id = test_game AND actor_id = rear_actor;
    frame := doom.render(test_game, width, height);
    IF pg_temp.sprite_pixel(frame, width, 16, 20) IS DISTINCT FROM '\x102030'::bytea THEN
        RAISE EXCEPTION 'An opaque wall must hide a sprite behind it';
    END IF;

    UPDATE doom.actors SET x = 16, z = 42, sector_id = 1, health = 0
    WHERE game_id = test_game AND actor_id = rear_actor;
    frame := doom.render(test_game, width, height);
    IF pg_temp.sprite_pixel(frame, width, 16, 20) IS DISTINCT FROM '\x102030'::bytea
        OR pg_temp.sprite_pixel(frame, width, 17, 20) IS DISTINCT FROM '\x701040'::bytea
        OR pg_temp.sprite_pixel(frame, width, 17, 19) IS DISTINCT FROM '\x102030'::bytea
    THEN
        RAISE EXCEPTION 'A dead actor must use its bound sprite and signed pivot at normal sector light';
    END IF;

    UPDATE doom.actor_types SET radius = 2, dead_sprite_material = 'MISSING'
    WHERE kind = 'sprite-fixture-sign';
    UPDATE doom.actors SET z = 33 WHERE game_id = test_game AND actor_id = rear_actor;
    IF pg_temp.sprite_pixel(doom.render(test_game, width, height), width, 16, 20)
        IS DISTINCT FROM '\x0b4422'::bytea
    THEN
        RAISE EXCEPTION 'A missing dead sprite must use the shaded fallback silhouette';
    END IF;

    UPDATE doom.actors SET health = 5 WHERE game_id = test_game AND actor_id = rear_actor;
    DELETE FROM doom.level_palettes WHERE level_id = test_level;
    IF pg_temp.sprite_pixel(doom.render(test_game, width, height), width, 16, 20)
        IS DISTINCT FROM '\x116633'::bytea
    THEN
        RAISE EXCEPTION 'A game without a palette must render the living fallback silhouette';
    END IF;
END;
$$;

ROLLBACK;
