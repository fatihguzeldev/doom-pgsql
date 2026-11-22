\set ON_ERROR_STOP on
BEGIN;

DO $$
DECLARE
    test_level bigint;
    test_game bigint;
    empty_game bigint;
    reverse_game bigint;
    frame bytea;
BEGIN
    INSERT INTO doom.levels (name) VALUES ('Two colored rooms')
    RETURNING level_id INTO test_level;

    INSERT INTO doom.sectors
        (level_id, sector_id, floor_height, ceiling_height, light_level, floor_color, ceiling_color)
    VALUES
        (test_level, 0, 0, 96, 255, x'FF9933'::integer, x'3366CC'::integer),
        (test_level, 1, 0, 96, 255, x'006060'::integer, x'2244BB'::integer);

    INSERT INTO doom.lines
        (level_id, line_id, x1, y1, x2, y2, front_sector_id, back_sector_id, blocking, wall_color)
    VALUES
        (test_level, 0, 64, 64, 64, -64, 0, 1, true, x'D0A010'::integer),
        (test_level, 1, 128, 64, 128, 0, 1, NULL, true, x'B02060'::integer),
        (test_level, 2, 128, 0, 128, -64, 1, NULL, true, x'009090'::integer),
        (test_level, 3, -64, -64, -64, 64, 0, NULL, true, x'40B050'::integer);

    INSERT INTO doom.games (level_id) VALUES (test_level)
    RETURNING game_id INTO test_game;

    INSERT INTO doom.actors (game_id, sector_id, kind, x, y)
    VALUES (test_game, 0, 'player', 0, 0);

    frame := doom.render(test_game, 7, 9);

    IF octet_length(frame) IS DISTINCT FROM 7 * 9 * 3 THEN
        RAISE EXCEPTION 'Expected a 7x9 packed RGB frame';
    END IF;

    -- The middle ray looks through both rooms. These are the colors at column 3.
    IF substring(frame FROM (0 * 7 + 3) * 3 + 1 FOR 3) IS DISTINCT FROM decode('3366CC', 'hex')
        OR substring(frame FROM (1 * 7 + 3) * 3 + 1 FOR 3) IS DISTINCT FROM decode('2244BB', 'hex')
        OR substring(frame FROM (4 * 7 + 3) * 3 + 1 FOR 3) IS DISTINCT FROM decode('B02060', 'hex')
        OR substring(frame FROM (6 * 7 + 3) * 3 + 1 FOR 3) IS DISTINCT FROM decode('006060', 'hex')
        OR substring(frame FROM (8 * 7 + 3) * 3 + 1 FOR 3) IS DISTINCT FROM decode('FF9933', 'hex')
    THEN
        RAISE EXCEPTION 'Open portal did not reveal the expected surfaces';
    END IF;

    IF substring(frame FROM (4 * 7 + 2) * 3 + 1 FOR 3) IS DISTINCT FROM decode('B02060', 'hex')
        OR substring(frame FROM (4 * 7 + 4) * 3 + 1 FOR 3) IS DISTINCT FROM decode('009090', 'hex')
    THEN
        RAISE EXCEPTION 'A wall split at a vertex must preserve left/right and depth ties';
    END IF;

    IF frame IS DISTINCT FROM doom.render(test_game, 7, 9)
        OR (SELECT tick_number FROM doom.games WHERE game_id = test_game) <> 0
    THEN
        RAISE EXCEPTION 'Rendering the same game must be deterministic and leave its clock alone';
    END IF;

    INSERT INTO doom.games (level_id) VALUES (test_level)
    RETURNING game_id INTO reverse_game;
    INSERT INTO doom.actors (game_id, sector_id, kind, x, y, angle)
    VALUES (reverse_game, 1, 'player', 96, 0, pi());

    frame := doom.render(reverse_game, 7, 9);
    IF substring(frame FROM (4 * 7 + 3) * 3 + 1 FOR 3) IS DISTINCT FROM decode('40B050', 'hex') THEN
        RAISE EXCEPTION 'The reverse view must traverse a two-sided line from the back';
    END IF;

    INSERT INTO doom.sector_state (game_id, level_id, sector_id, floor_height, ceiling_height)
    VALUES (test_game, test_level, 1, 60, 96);
    frame := doom.render(test_game, 7, 9);
    IF substring(frame FROM (1 * 7 + 3) * 3 + 1 FOR 3) IS DISTINCT FROM decode('2244BB', 'hex')
        OR substring(frame FROM (4 * 7 + 3) * 3 + 1 FOR 3) IS DISTINCT FROM decode('D0A010', 'hex')
    THEN
        RAISE EXCEPTION 'A raised destination floor must clip the portal from below';
    END IF;

    UPDATE doom.sector_state SET floor_height = 0, ceiling_height = 0
    WHERE game_id = test_game AND sector_id = 1;

    frame := doom.render(test_game, 7, 9);
    IF substring(frame FROM (4 * 7 + 3) * 3 + 1 FOR 3) IS DISTINCT FROM decode('D0A010', 'hex') THEN
        RAISE EXCEPTION 'A closed portal must hide the far room';
    END IF;

    IF octet_length(doom.render(test_game, 1, 1)) IS DISTINCT FROM 3 THEN
        RAISE EXCEPTION 'One-pixel frames must still contain one RGB sample';
    END IF;

    -- One endpoint is behind the camera. The central ray hits the visible part.
    INSERT INTO doom.lines
        (level_id, line_id, x1, y1, x2, y2, front_sector_id, blocking, wall_color)
    VALUES (test_level, 4, 128, 64, -64, -64, 0, true, x'C05080'::integer);

    frame := doom.render(test_game, 7, 9);
    IF substring(frame FROM (4 * 7 + 3) * 3 + 1 FOR 3) IS DISTINCT FROM decode('C05080', 'hex') THEN
        RAISE EXCEPTION 'Near clipping must keep the visible part of a wall';
    END IF;

    BEGIN
        PERFORM doom.render(test_game, 0, 30);
        RAISE EXCEPTION 'Zero width should fail';
    EXCEPTION WHEN invalid_parameter_value THEN
        NULL;
    END;

    BEGIN
        PERFORM doom.render(test_game, NULL, 30);
        RAISE EXCEPTION 'NULL width should fail';
    EXCEPTION WHEN invalid_parameter_value THEN
        NULL;
    END;

    BEGIN
        PERFORM doom.render(test_game, 4096, 4096);
        RAISE EXCEPTION 'Oversized frames should fail';
    EXCEPTION WHEN invalid_parameter_value THEN
        NULL;
    END;

    BEGIN
        PERFORM doom.render(-1, 30, 30);
        RAISE EXCEPTION 'An unknown game should fail';
    EXCEPTION WHEN no_data_found THEN
        NULL;
    END;

    INSERT INTO doom.games (level_id) VALUES (test_level)
    RETURNING game_id INTO empty_game;

    BEGIN
        PERFORM doom.render(empty_game, 30, 30);
        RAISE EXCEPTION 'A game with no camera should fail';
    EXCEPTION WHEN no_data_found THEN
        NULL;
    END;
END;
$$;

ROLLBACK;
