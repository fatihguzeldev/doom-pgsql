BEGIN;
SET LOCAL plpgsql.check_asserts = on;

DO $$
DECLARE
    test_level bigint;
    test_game bigint;
    single_tick_game bigint;
    other_game bigint;
    blocker bigint;
    player doom.actors;
    moved doom.actors;
    tolerance constant double precision := 0.00002;
BEGIN
    INSERT INTO doom.levels (name) VALUES ('actor contact') RETURNING level_id INTO test_level;
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height)
    VALUES (test_level, 0, 0, 128);
    INSERT INTO doom.actor_types (kind, default_health, radius, height) VALUES ('blocker', 80, 12, 24);

    test_game := doom.start_game(test_level, 0, 32, 0);
    single_tick_game := doom.start_game(test_level, 0, 32, 0);
    INSERT INTO doom.actors (game_id, sector_id, kind, x, y)
    VALUES (test_game, 0, 'blocker', 80, 0) RETURNING actor_id INTO blocker;
    INSERT INTO doom.actors (game_id, sector_id, kind, x, y)
    VALUES (single_tick_game, 0, 'blocker', 80, 0);

    PERFORM doom.tick(test_game, 1, 0, 0, 5);
    SELECT * INTO STRICT player FROM doom.actors WHERE game_id = test_game AND kind = 'player';
    ASSERT abs(player.x - 52) < tolerance AND player.y = 0,
        format('the player stops where its radius meets a live actor radius, got x=%s', player.x);

    FOR tic IN 1..5 LOOP
        PERFORM doom.tick(single_tick_game, 1);
    END LOOP;
    ASSERT (SELECT x FROM doom.actors WHERE game_id = single_tick_game AND kind = 'player') = player.x,
        'batched and single ticks agree against a stationary actor';

    player.x := 32;
    moved := doom.move_actor(player, 120, 0, 56, 16);
    ASSERT abs(moved.x - 52) < tolerance AND moved.y = 0, 'a long sweep cannot tunnel through an actor';
    moved := doom.move_actor(player, 120, 0, 56);
    ASSERT moved.x = 152, 'a point move passes straight through an actor';

    player.y := 12;
    moved := doom.move_actor(player, 120, 0, 56, 16);
    ASSERT abs(moved.x - (80 - sqrt(28.0 ^ 2 - 12.0 ^ 2))) < tolerance AND moved.y = 12,
        'a sweep hits the outside of the blocker when its center path misses';

    player.y := 28;
    moved := doom.move_actor(player, 120, 0, 56, 16);
    ASSERT moved.x = 152 AND moved.y = 28, 'an exactly tangent path stays passable';

    player.x := 60;
    player.y := 0;
    moved := doom.move_actor(player, -24, 0, 56, 16);
    ASSERT moved.x = 36, 'an overlapping actor can move clear of a blocker';
    moved := doom.move_actor(player, 12, 0, 56, 16);
    ASSERT moved.x = 60, 'an overlapping actor cannot move deeper into a blocker';

    player.x := 32;
    UPDATE doom.actors SET z = 56 WHERE game_id = test_game AND actor_id = blocker;
    moved := doom.move_actor(player, 120, 0, 56, 16);
    ASSERT moved.x = 152, 'an actor whose feet touch the player top does not block';
    UPDATE doom.actors SET z = 55 WHERE game_id = test_game AND actor_id = blocker;
    moved := doom.move_actor(player, 120, 0, 56, 16);
    ASSERT abs(moved.x - 52) < tolerance, 'an actor just below the player top blocks';
    UPDATE doom.actors SET z = 0 WHERE game_id = test_game AND actor_id = blocker;

    UPDATE doom.actor_types SET blocks_actors = false WHERE kind = 'blocker';
    moved := doom.move_actor(player, 120, 0, 56, 16);
    ASSERT moved.x = 152, 'actors of a nonsolid type do not block';
    UPDATE doom.actor_types SET blocks_actors = true, radius = 0 WHERE kind = 'blocker';
    moved := doom.move_actor(player, 120, 0, 56, 16);
    ASSERT moved.x = 152, 'actors with zero radius do not block';
    UPDATE doom.actor_types SET radius = 12 WHERE kind = 'blocker';

    other_game := doom.start_game(test_level, 0, 56, 0);
    INSERT INTO doom.actors (game_id, sector_id, kind, x, y) VALUES (other_game, 0, 'blocker', 96, 0);
    player.x := 0;
    moved := doom.move_actor(player, 120, 0, 56, 16);
    ASSERT abs(moved.x - 52) < tolerance, 'the stored mover and actors from other games do not block';

    UPDATE doom.actors SET health = 0 WHERE game_id = test_game AND actor_id = blocker;
    PERFORM doom.tick(test_game, 1, 0, 0, 5);
    ASSERT abs((SELECT x FROM doom.actors WHERE game_id = test_game AND kind = 'player') - 92) < tolerance,
        'an actor killed through SQL no longer blocks a tick';

    player.x := -112;
    UPDATE doom.actors SET x = -80, health = 80 WHERE game_id = test_game AND actor_id = blocker;
    moved := doom.move_actor(player, 40, 0, 56, 16);
    ASSERT abs(moved.x + 108) < tolerance, 'a blocker at a negative x coordinate stops movement';
    UPDATE doom.actors SET x = -60 WHERE game_id = test_game AND actor_id = blocker;
    moved := doom.move_actor(player, 40, 0, 56, 16);
    ASSERT abs(moved.x + 88) < tolerance, 'an actor moved through SQL blocks at its new coordinate';
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
    INSERT INTO doom.levels (name) VALUES ('actor contact at portal') RETURNING level_id INTO test_level;
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height)
    VALUES (test_level, 0, 0, 128), (test_level, 1, 0, 128);
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id, back_sector_id)
    VALUES (test_level, 0, 64, 96, 64, -96, 0, 1);
    INSERT INTO doom.actor_types (kind, default_health, radius) VALUES ('wide blocker', 80, 20);

    test_game := doom.start_game(test_level, 0, 32, 0);
    INSERT INTO doom.actors (game_id, sector_id, kind, x, y)
    VALUES (test_game, 1, 'wide blocker', 75, 0);
    SELECT * INTO STRICT player FROM doom.actors WHERE game_id = test_game AND kind = 'player';

    moved := doom.move_actor(player, 90, 0, 56, 16);
    ASSERT abs(moved.x - 39) < tolerance AND moved.sector_id = 0,
        format('the blocker extends through an open portal before the player enters, got x=%s', moved.x);

    INSERT INTO doom.sector_state (game_id, level_id, sector_id, floor_height, ceiling_height)
    VALUES (test_game, test_level, 1, 16, 128);
    UPDATE doom.actors SET x = 112, z = 56 WHERE game_id = test_game AND kind = 'wide blocker';
    moved := doom.move_actor(player, 90, 0, 56, 16);
    ASSERT abs(moved.x - 76) < tolerance AND moved.sector_id = 1 AND moved.z = 16,
        'stepping up through a portal can bring the player into contact with a blocker';

    UPDATE doom.sector_state SET floor_height = 0, ceiling_height = 55 WHERE game_id = test_game;
    UPDATE doom.actors SET x = 75, z = 0 WHERE game_id = test_game AND kind = 'wide blocker';
    moved := doom.move_actor(player, 90, 0, 56, 16);
    ASSERT abs(moved.x - 48) < tolerance AND moved.sector_id = 0,
        'the player reaches the lip of a closed portal instead of touching an actor beyond it';

    DELETE FROM doom.sector_state WHERE game_id = test_game;
    UPDATE doom.lines SET back_sector_id = NULL WHERE level_id = test_level AND line_id = 0;
    moved := doom.move_actor(player, 90, 0, 56, 16);
    ASSERT abs(moved.x - 48) < tolerance AND moved.sector_id = 0,
        'a solid wall screens an actor in another sector';

    UPDATE doom.lines SET back_sector_id = 0, blocking = true WHERE level_id = test_level AND line_id = 0;
    UPDATE doom.actors SET sector_id = 0 WHERE game_id = test_game AND kind = 'wide blocker';
    moved := doom.move_actor(player, 90, 0, 56, 16);
    ASSERT abs(moved.x - 48) < tolerance AND moved.sector_id = 0,
        'a blocking line screens an actor in the same sector';
END;
$$;

ROLLBACK;
