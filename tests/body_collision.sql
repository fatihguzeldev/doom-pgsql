BEGIN;
SET LOCAL plpgsql.check_asserts = on;

DO $$
DECLARE
    test_level bigint;
    test_game bigint;
    player doom.actors;
    moved doom.actors;
    tolerance constant double precision := 0.00002;
BEGIN
    INSERT INTO doom.levels (name) VALUES ('short wall') RETURNING level_id INTO test_level;
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height)
    VALUES (test_level, 0, 0, 128);
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id)
    VALUES (test_level, 0, 50, 80, 50, 0, 0);

    test_game := doom.start_game(test_level, 0, 32, 32);
    PERFORM doom.tick(test_game, 1, 0, 0, 4);
    SELECT * INTO STRICT player FROM doom.actors WHERE game_id = test_game AND kind = 'player';
    ASSERT abs(player.x - 34) < tolerance AND player.y = 32,
        format('ticks stop one player radius from the wall, got x=%s', player.x);

    player.x := 20;
    moved := doom.move_actor(player, 120, 0, 56, 16);
    ASSERT abs(moved.x - 34) < tolerance, 'a long sweep cannot tunnel through the wall';

    player.y := -12;
    moved := doom.move_actor(player, 120, 0, 56, 16);
    ASSERT abs(moved.x - (50 - sqrt(16.0 ^ 2 - 12.0 ^ 2))) < tolerance AND moved.y = -12,
        'a body can hit the end of the wall when its center path misses the line';

    player.y := -16;
    moved := doom.move_actor(player, 120, 0, 56, 16);
    ASSERT moved.x = 140 AND moved.y = -16, 'a path tangent to the endpoint stays passable';

    player.x := 42;
    player.y := 32;
    moved := doom.move_actor(player, -24, 0, 56, 16);
    ASSERT moved.x = 18, 'an overlapping actor can move clear of the wall';
    moved := doom.move_actor(player, 0, 8, 56, 16);
    ASSERT moved.x = 42 AND moved.y = 40, 'parallel motion does not deepen overlap';
    moved := doom.move_actor(player, 12, 0, 56, 16);
    ASSERT moved.x = 42, 'an overlapping actor cannot move deeper into the wall';

    UPDATE doom.actor_types SET radius = 0 WHERE kind = 'player';
    PERFORM doom.tick(test_game, 1, 0, 0, 4);
    ASSERT abs((SELECT x FROM doom.actors WHERE game_id = test_game AND kind = 'player') - 50) < tolerance,
        'a zero-radius type uses point collision';
END;
$$;

ROLLBACK;

BEGIN;
SET LOCAL plpgsql.check_asserts = on;

DO $$
DECLARE
    test_level bigint;
    test_game bigint;
    player doom.actors;
    moved doom.actors;
    tolerance constant double precision := 0.00002;
BEGIN
    INSERT INTO doom.levels (name) VALUES ('portal and jambs') RETURNING level_id INTO test_level;
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height)
    VALUES (test_level, 0, 0, 128), (test_level, 1, 0, 128), (test_level, 2, 16, 72);
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id, back_sector_id)
    VALUES (test_level, 0, 64, 96, 64, -96, 0, 1);

    test_game := doom.start_game(test_level, 0, 32, 0);
    INSERT INTO doom.sector_state (game_id, level_id, sector_id, floor_height, ceiling_height)
    VALUES (test_game, test_level, 1, 0, 55);
    SELECT * INTO STRICT player FROM doom.actors WHERE game_id = test_game AND kind = 'player';

    moved := doom.move_actor(player, 50, 0, 56, 16);
    ASSERT abs(moved.x - 48) < tolerance AND moved.sector_id = 0, 'a low ceiling blocks the body';

    UPDATE doom.sector_state SET floor_height = 17, ceiling_height = 128 WHERE game_id = test_game;
    moved := doom.move_actor(player, 50, 0, 56, 16);
    ASSERT abs(moved.x - 48) < tolerance AND moved.sector_id = 0, 'a high step blocks the body';

    UPDATE doom.sector_state SET floor_height = 16, ceiling_height = 72 WHERE game_id = test_game;
    moved := doom.move_actor(player, 50, 0, 56, 16);
    ASSERT moved.x = 82 AND moved.sector_id = 1 AND moved.z = 16,
        'a portal admits the body at exact step and ceiling clearance';

    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id)
    VALUES (test_level, 1, 72, 96, 72, -96, 1);
    player.x := 53;
    moved := doom.move_actor(player, 8, 0, 56, 16);
    ASSERT abs(moved.x - 56) < tolerance AND moved.sector_id = 0,
        'a wall just beyond an open portal can stop the body before its center enters';

    UPDATE doom.lines SET back_sector_id = 2 WHERE level_id = test_level AND line_id = 1;
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id)
    VALUES (test_level, 2, 75, 96, 75, -96, 2);
    moved := doom.move_actor(player, 8, 0, 56, 16);
    ASSERT abs(moved.x - 59) < tolerance AND moved.sector_id = 0,
        'the body can reach a wall beyond two open portals in the same sweep';

    DELETE FROM doom.lines WHERE level_id = test_level AND line_id IN (1, 2);
    UPDATE doom.lines SET y1 = 10, y2 = -10 WHERE level_id = test_level AND line_id = 0;
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id)
    VALUES (test_level, 1, 64, 96, 64, 10, 0),
           (test_level, 2, 64, -10, 64, -96, 0);

    player.x := 32;
    moved := doom.move_actor(player, 50, 0, 56, 16);
    ASSERT abs(moved.x - (64 - sqrt(16.0 ^ 2 - 10.0 ^ 2))) < tolerance AND moved.sector_id = 0,
        'the jambs block a body wider than the open portal';
    moved := doom.move_actor(player, 50, 0, 56, 10);
    ASSERT moved.x = 82 AND moved.sector_id = 1, 'an exactly fitting body passes the jambs';
END;
$$;

ROLLBACK;
