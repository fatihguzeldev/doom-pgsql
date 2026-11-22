BEGIN;
SET LOCAL plpgsql.check_asserts = on;

DO $$
DECLARE
    test_level bigint;
    test_game bigint;
    other_game bigint;
    pursuer_id bigint;
    first_action integer;
    before_frame bytea;
    after_frame bytea;
    tolerance constant double precision := 0.00002;
BEGIN
    INSERT INTO doom.levels (name) VALUES ('pursuit passage fixture') RETURNING level_id INTO test_level;
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height)
    VALUES (test_level, 0, 0, 128), (test_level, 1, 0, 128);
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id, back_sector_id)
    VALUES (test_level, 0, 64, 64, 64, -64, 0, 1),
           (test_level, 1, -64, -64, -64, 64, 0, NULL),
           (test_level, 2, -64, 64, 64, 64, 0, NULL),
           (test_level, 3, 64, -64, -64, -64, 0, NULL),
           (test_level, 4, 64, 64, 192, 64, 1, NULL),
           (test_level, 5, 192, 64, 192, -64, 1, NULL),
           (test_level, 6, 192, -64, 64, -64, 1, NULL);
    INSERT INTO doom.actor_types (kind, default_health, radius)
    VALUES ('passage pursuer fixture', 30, 8);
    INSERT INTO doom.actor_pursuits (kind, sight_range, move_distance, interval_ticks)
    VALUES ('passage pursuer fixture', 72, 16, 3);

    test_game := doom.start_game(test_level, 0, 16, 0);
    other_game := doom.start_game(test_level, 0, 16, 0);
    INSERT INTO doom.actors (game_id, sector_id, kind, x, y)
    VALUES (test_game, 1, 'passage pursuer fixture', 104, 0) RETURNING actor_id INTO pursuer_id;
    INSERT INTO doom.actors (game_id, sector_id, kind, x, y)
    VALUES (other_game, 1, 'passage pursuer fixture', 104, 0);
    first_action := (pursuer_id - 1) % 3 + 1;
    INSERT INTO doom.sector_state (game_id, level_id, sector_id, floor_height, ceiling_height)
    VALUES (test_game, test_level, 0, 0, 32);

    PERFORM doom.tick(test_game, p_ticks => first_action);
    ASSERT (SELECT x FROM doom.actors WHERE game_id = test_game AND actor_id = pursuer_id) = 104,
        'a portal below eye height hides the player on the scheduled tic';

    UPDATE doom.sector_state SET ceiling_height = 128 WHERE game_id = test_game AND sector_id = 0;
    PERFORM doom.tick(test_game, p_ticks => 2);
    ASSERT (SELECT x FROM doom.actors WHERE game_id = test_game AND actor_id = pursuer_id) = 104,
        'an open passage leaves the actor stationary between scheduled actions';

    before_frame := doom.render(test_game, 40, 32);
    BEGIN
        PERFORM doom.step(test_game, 0, 32);
        RAISE EXCEPTION 'expected the frame to reject zero width';
    EXCEPTION WHEN invalid_parameter_value THEN
        NULL;
    END;
    ASSERT (SELECT tick_number FROM doom.games WHERE game_id = test_game) = first_action + 2
        AND (SELECT x FROM doom.actors WHERE game_id = test_game AND actor_id = pursuer_id) = 104,
        'a failed frame rolls back the scheduled pursuit action and tic';

    after_frame := doom.step(test_game, 40, 32);
    ASSERT (SELECT x FROM doom.actors WHERE game_id = test_game AND actor_id = pursuer_id) = 88,
        'the idle game advances the pursuer when the player body reaches the sight limit';
    ASSERT after_frame = doom.render(test_game, 40, 32) AND after_frame <> before_frame,
        'the combined request renders the advanced pursuer';
    PERFORM doom.tick(test_game, p_ticks => 6);
    ASSERT EXISTS (SELECT FROM doom.actors WHERE game_id = test_game AND actor_id = pursuer_id
                   AND x = 56 AND sector_id = 0), 'following the player crosses the open portal';

    UPDATE doom.actors SET health = 0 WHERE game_id = test_game AND actor_id = pursuer_id;
    PERFORM doom.tick(test_game, p_ticks => 3);
    ASSERT (SELECT x FROM doom.actors WHERE game_id = test_game AND actor_id = pursuer_id) = 56,
        'a dead pursuer stays in place on its action tic';
    UPDATE doom.actors SET health = 30 WHERE game_id = test_game AND actor_id = pursuer_id;
    PERFORM doom.tick(test_game, p_ticks => 3);
    ASSERT (SELECT abs(x - 40) < tolerance FROM doom.actors WHERE game_id = test_game AND actor_id = pursuer_id),
        'a revived pursuer moves up to the player body';
    ASSERT (SELECT x FROM doom.actors WHERE game_id = other_game AND kind = 'passage pursuer fixture') = 104,
        'ticking one game leaves the other game''s pursuer at its spawn position';

    UPDATE doom.actor_pursuits SET sight_range = 256, move_distance = 1, interval_ticks = 1
    WHERE kind = 'passage pursuer fixture';
    UPDATE doom.actors SET x = 0 WHERE game_id = other_game AND kind = 'player';
    UPDATE doom.actors SET x = 96, y = '5e-324'::double precision
    WHERE game_id = other_game AND kind = 'passage pursuer fixture';
    PERFORM doom.tick(other_game);
    ASSERT EXISTS (SELECT FROM doom.actors WHERE game_id = other_game AND kind = 'passage pursuer fixture'
                   AND x = 95 AND y = '5e-324'::double precision),
        'a nearly axis-aligned approach still advances without floating-point underflow';
END;
$$;

DO $$
DECLARE
    test_level bigint;
    batched_game bigint;
    single_game bigint;
    screened_game bigint;
    screen_id bigint;
    batched_player doom.actors;
    single_player doom.actors;
BEGIN
    INSERT INTO doom.levels (name) VALUES ('pursuit engagement fixture') RETURNING level_id INTO test_level;
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height) VALUES (test_level, 0, 0, 128);
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id)
    VALUES (test_level, 0, -64, -64, -64, 64, 0),
           (test_level, 1, -64, 64, 192, 64, 0),
           (test_level, 2, 192, 64, 192, -64, 0),
           (test_level, 3, 192, -64, -64, -64, 0);
    INSERT INTO doom.actor_types (kind, default_health, radius, attack_range, attack_damage)
    VALUES ('stationary pursuer fixture', 30, 8, 40, 25), ('screening actor fixture', 30, 6, 0, 0);
    INSERT INTO doom.actor_pursuits (kind, sight_range, move_distance, interval_ticks)
    VALUES ('stationary pursuer fixture', 128, 0, 1);

    batched_game := doom.start_game(test_level, 0, 0, 0);
    single_game := doom.start_game(test_level, 0, 0, 0);
    screened_game := doom.start_game(test_level, 0, 12, 0);
    INSERT INTO doom.actors (game_id, sector_id, kind, x, y)
    VALUES (batched_game, 0, 'stationary pursuer fixture', 64, 0),
           (single_game, 0, 'stationary pursuer fixture', 64, 0),
           (screened_game, 0, 'stationary pursuer fixture', 64, 0);
    INSERT INTO doom.actors (game_id, sector_id, kind, x, y)
    VALUES (screened_game, 0, 'screening actor fixture', 40, 0) RETURNING actor_id INTO screen_id;

    PERFORM doom.tick(screened_game);
    ASSERT (SELECT health FROM doom.actors WHERE game_id = screened_game AND actor_id = screen_id) = 30
        AND (SELECT health FROM doom.actors WHERE game_id = screened_game AND kind = 'player') = 100,
        'the first living body screens the player and remains unharmed';
    UPDATE doom.actors SET health = 0 WHERE game_id = screened_game AND actor_id = screen_id;
    PERFORM doom.tick(screened_game);
    ASSERT (SELECT health FROM doom.actors WHERE game_id = screened_game AND kind = 'player') = 75,
        'the stationary pursuer attacks on an unobstructed line';
    UPDATE doom.actors SET health = 20 WHERE game_id = screened_game AND kind = 'stationary pursuer fixture';
    PERFORM doom.tick(screened_game, p_fire => true);
    ASSERT (SELECT health FROM doom.actors WHERE game_id = screened_game AND kind = 'stationary pursuer fixture') = 0
        AND (SELECT health FROM doom.actors WHERE game_id = screened_game AND kind = 'player') = 75,
        'a lethal player shot resolves before the pursuer can return fire';

    UPDATE doom.actors SET health = 25 WHERE game_id IN (batched_game, single_game) AND kind = 'player';
    PERFORM doom.tick(batched_game, p_forward => 1, p_ticks => 4);
    FOR tic IN 1..4 LOOP
        PERFORM doom.tick(single_game, p_forward => 1);
    END LOOP;
    SELECT * INTO STRICT batched_player FROM doom.actors WHERE game_id = batched_game AND kind = 'player';
    SELECT * INTO STRICT single_player FROM doom.actors WHERE game_id = single_game AND kind = 'player';
    ASSERT batched_player.x = 8 AND batched_player.health = 0 AND batched_player.animation_start_tick = 1,
        'the first player move enters attack range and a lethal hit ends movement on that tic';
    ASSERT (batched_player.x, batched_player.y, batched_player.angle, batched_player.health, batched_player.animation_start_tick)
         = (single_player.x, single_player.y, single_player.angle, single_player.health, single_player.animation_start_tick)
        AND (SELECT tick_number FROM doom.games WHERE game_id = batched_game) = 4,
        'one movement batch advances the same state as four individual tics';
END;
$$;

ROLLBACK;
