BEGIN;
SET LOCAL plpgsql.check_asserts = on;

DO $$
DECLARE
    test_level bigint;
    first_game bigint;
    second_game bigint;
    spawned doom.actors;
BEGIN
    INSERT INTO doom.levels (name) VALUES ('test courtyard') RETURNING level_id INTO test_level;
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height)
    VALUES (test_level, 3, 8, 96);
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id)
    VALUES (test_level, 0, 0, 0, 0, 64, 3),
           (test_level, 1, 0, 64, 64, 64, 3),
           (test_level, 2, 64, 64, 64, 0, 3),
           (test_level, 3, 64, 0, 0, 0, 3);

    INSERT INTO doom.games (level_id) VALUES (test_level) RETURNING game_id INTO first_game;
    INSERT INTO doom.games (level_id) VALUES (test_level) RETURNING game_id INTO second_game;
    INSERT INTO doom.sector_state (game_id, level_id, sector_id, floor_height, ceiling_height)
    VALUES (first_game, test_level, 3, 24, 96);

    INSERT INTO doom.actor_types (kind, default_health) VALUES ('test drone', 37);
    INSERT INTO doom.actors (game_id, kind, x, y)
    VALUES (first_game, 'test drone', 32, 32) RETURNING * INTO spawned;
    ASSERT spawned.health = 37 AND spawned.life_state = 'alive', 'spawn uses actor type defaults';
    ASSERT spawned.sector_id = 3 AND spawned.z = 24, 'spawn uses the game floor at its position';

    UPDATE doom.actors SET health = 0 WHERE game_id = first_game AND actor_id = spawned.actor_id
    RETURNING * INTO spawned;
    ASSERT spawned.life_state = 'dead', 'SQL health updates immediately change life state';

    INSERT INTO doom.actors (game_id, kind, x, y)
    VALUES (second_game, 'test drone', 32, 32) RETURNING * INTO spawned;
    ASSERT spawned.z = 8 AND spawned.health = 37, 'a different game uses the unmodified level';

    BEGIN
        INSERT INTO doom.actors (game_id, kind, x, y) VALUES (second_game, 'test drone', 80, 32);
        RAISE EXCEPTION 'expected spawn outside the level to fail';
    EXCEPTION WHEN check_violation THEN
        NULL;
    END;
END;
$$;

ROLLBACK;
