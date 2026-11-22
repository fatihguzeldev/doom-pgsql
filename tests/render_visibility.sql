BEGIN;

DO $$
DECLARE
    level bigint;
    game bigint;
    near_actor bigint;
    frame bytea;
BEGIN
    INSERT INTO doom.levels (name) VALUES ('disjoint portal visibility') RETURNING level_id INTO level;
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height, light_level)
    VALUES (level, 0, 0, 96, 255), (level, 1, 0, 96, 255), (level, 2, 0, 96, 255);
    INSERT INTO doom.lines
        (level_id, line_id, x1, y1, x2, y2, front_sector_id, back_sector_id, wall_color)
    VALUES (level, 0, 64, 64, 64, 24, 0, 1, x'112233'::integer),
           (level, 1, 64, 24, 64, -24, 0, NULL, x'A06020'::integer),
           (level, 2, 64, -24, 64, -64, 0, 1, x'112233'::integer),
           (level, 3, 96, 96, 96, -96, 1, 2, x'204060'::integer),
           (level, 4, 128, 128, 128, -128, 2, NULL, x'603090'::integer);
    game := doom.start_game(level, 0, 0, 0);
    frame := doom.render(game, 9, 9);
    IF substring(frame FROM (4 * 9 + 1) * 3 + 1 FOR 3) IS DISTINCT FROM '\x603090'::bytea
        OR substring(frame FROM (4 * 9 + 7) * 3 + 1 FOR 3) IS DISTINCT FROM '\x603090'::bytea
        OR substring(frame FROM (4 * 9 + 4) * 3 + 1 FOR 3) IS DISTINCT FROM '\xA06020'::bytea
    THEN
        RAISE EXCEPTION 'two windows into the same sector must keep both openings and the intervening wall';
    END IF;

    INSERT INTO doom.actor_types (kind, default_health, radius, height, color)
    VALUES ('visibility-near', 5, 12, 70, x'44DD66'::integer),
           ('visibility-far', 5, 12, 70, x'AA3399'::integer);
    INSERT INTO doom.actors (game_id, sector_id, kind, x, y)
    VALUES (game, 2, 'visibility-far', 112, 0);
    INSERT INTO doom.actors (game_id, sector_id, kind, x, y)
    VALUES (game, 0, 'visibility-near', 32, 0) RETURNING actor_id INTO near_actor;
    IF substring(doom.render(game, 9, 9) FROM (4 * 9 + 4) * 3 + 1 FOR 3) IS DISTINCT FROM '\x44DD66'::bytea THEN
        RAISE EXCEPTION 'closing a screen region must retain sprites in front of its wall';
    END IF;
    UPDATE doom.actors SET health = 0 WHERE game_id = game AND actor_id = near_actor;
    IF substring(doom.render(game, 9, 9) FROM (4 * 9 + 4) * 3 + 1 FOR 3) IS DISTINCT FROM '\xA06020'::bytea THEN
        RAISE EXCEPTION 'closing a screen region must reject sprites behind its wall';
    END IF;

    INSERT INTO doom.sector_state (game_id, level_id, sector_id, floor_height, ceiling_height)
    VALUES (game, level, 2, 0, 0);
    frame := doom.render(game, 9, 9);
    IF substring(frame FROM (4 * 9 + 1) * 3 + 1 FOR 3) IS DISTINCT FROM '\x204060'::bytea
        OR substring(frame FROM (4 * 9 + 7) * 3 + 1 FOR 3) IS DISTINCT FROM '\x204060'::bytea
    THEN
        RAISE EXCEPTION 'a live door behind the initial windows must seal both paths';
    END IF;

    DELETE FROM doom.sector_state WHERE game_id = game AND sector_id = 2;
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height, light_level)
    VALUES (level, 3, 0, 96, 255), (level, 4, 0, 96, 255);
    UPDATE doom.lines SET back_sector_id = 3 WHERE level_id = level AND line_id = 4;
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id, back_sector_id, wall_color)
    VALUES (level, 5, 160, 160, 160, -160, 3, 4, x'31575F'::integer),
           (level, 6, 192, 192, 192, -192, 4, NULL, x'42B87D'::integer);
    frame := doom.render(game, 9, 9);
    IF substring(frame FROM (4 * 9 + 1) * 3 + 1 FOR 3) IS DISTINCT FROM '\x42B87D'::bytea
        OR substring(frame FROM (4 * 9 + 7) * 3 + 1 FOR 3) IS DISTINCT FROM '\x42B87D'::bytea
        OR substring(frame FROM (4 * 9 + 4) * 3 + 1 FOR 3) IS DISTINCT FROM '\xA06020'::bytea
    THEN
        RAISE EXCEPTION 'a deep portal chain must retain distant surfaces behind both windows';
    END IF;
END;
$$;

ROLLBACK;
