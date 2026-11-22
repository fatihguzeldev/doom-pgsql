BEGIN;
SET LOCAL plpgsql.check_asserts = on;

DO $$
DECLARE
    test_level bigint;
    unconfigured_level bigint;
    batched_game bigint;
    replay_game bigint;
    rollback_game bigint;
    idle_game bigint;
    unconfigured_game bigint;
    doomed_game bigint;
    tick_result bigint;
    finished_player doom.actors;
    replayed_player doom.actors;
    frame bytea;
BEGIN
    INSERT INTO doom.levels (name) VALUES ('exit corridor fixture') RETURNING level_id INTO test_level;
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height)
    VALUES (test_level, 0, 0, 96), (test_level, 1, 0, 96);
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id, back_sector_id)
    VALUES (test_level, 0, 0, 0, 0, 64, 0, NULL),
           (test_level, 1, 0, 64, 64, 64, 0, NULL),
           (test_level, 2, 64, 64, 64, 0, 0, 1),
           (test_level, 3, 64, 0, 0, 0, 0, NULL),
           (test_level, 4, 64, 64, 192, 64, 1, NULL),
           (test_level, 5, 192, 64, 192, 0, 1, NULL),
           (test_level, 6, 192, 0, 64, 0, 1, NULL);
    INSERT INTO doom.level_exits (level_id, sector_id) VALUES (test_level, 1);
    INSERT INTO doom.level_things (level_id, thing_id, x, y, angle_deg, type_code, flags)
    VALUES (test_level, 0, 52, 32, 0, 1, 0);

    batched_game := doom.start_game(test_level);
    replay_game := doom.start_game(test_level);
    ASSERT doom.tick(batched_game, p_forward => 1, p_ticks => 6) = 2,
        'the batch stops at the first tic ending in the exit sector';
    ASSERT EXISTS (SELECT FROM doom.games WHERE game_id = batched_game
                   AND tick_number = 2 AND finished_at_tick = 2), 'the clock freezes at the completion tic';
    ASSERT EXISTS (SELECT FROM doom.games WHERE game_id = replay_game
                   AND tick_number = 0 AND finished_at_tick IS NULL), 'completion is scoped to its game';

    FOR iteration IN 1..6 LOOP
        PERFORM doom.tick(replay_game, p_forward => 1);
    END LOOP;
    ASSERT EXISTS (SELECT FROM doom.games WHERE game_id = replay_game
                   AND tick_number = 2 AND finished_at_tick = 2), 'single tics finish at the same clock as a batch';
    ASSERT doom.tick(batched_game, p_forward => -1, p_turn => 0.25, p_ticks => 5,
                     p_fire => true, p_use => true) = 2,
        'later input on a finished game returns its frozen clock';
    SELECT * INTO STRICT finished_player FROM doom.actors WHERE game_id = batched_game AND kind = 'player';
    SELECT * INTO STRICT replayed_player FROM doom.actors WHERE game_id = replay_game AND kind = 'player';
    ASSERT (finished_player.x, finished_player.y, finished_player.angle, finished_player.sector_id) = (68, 32, 0, 1)
        AND (finished_player.x, finished_player.y, finished_player.angle, finished_player.sector_id)
            = (replayed_player.x, replayed_player.y, replayed_player.angle, replayed_player.sector_id),
        'the frozen pose preserves the exit move and agrees with single-tic replay';

    rollback_game := doom.start_game(test_level, 0, 60, 32);
    BEGIN
        PERFORM doom.step(rollback_game, 0, 32, p_forward => 1, p_ticks => 4);
        RAISE EXCEPTION 'expected the frame to reject zero width';
    EXCEPTION WHEN invalid_parameter_value THEN
        NULL;
    END;
    ASSERT EXISTS (SELECT FROM doom.games WHERE game_id = rollback_game
                   AND tick_number = 0 AND finished_at_tick IS NULL)
        AND (SELECT x FROM doom.actors WHERE game_id = rollback_game AND kind = 'player') = 60,
        'a failed frame rolls back the exit move and completion';
    frame := doom.step_spans(rollback_game, 32, 32, p_forward => 1, p_ticks => 4);
    ASSERT EXISTS (SELECT FROM doom.games WHERE game_id = rollback_game
                   AND tick_number = 1 AND finished_at_tick = 1)
        AND frame = doom.render_spans(rollback_game, 32, 32), 'a step returns the frame of the completed pose';

    idle_game := doom.start_game(test_level, 1, 92, 32);
    tick_result := doom.tick(idle_game, p_ticks => 8);
    ASSERT tick_result = 1
        AND (SELECT finished_at_tick FROM doom.games WHERE game_id = idle_game) = 1,
        'spawning in an exit sector still completes on the first idle tic';

    INSERT INTO doom.levels (name) VALUES ('unconfigured exit fixture') RETURNING level_id INTO unconfigured_level;
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height)
    VALUES (unconfigured_level, 1, 0, 96);
    unconfigured_game := doom.start_game(unconfigured_level, 1, 92, 32);
    tick_result := doom.tick(unconfigured_game, p_ticks => 8);
    ASSERT tick_result = 8
        AND (SELECT finished_at_tick IS NULL FROM doom.games WHERE game_id = unconfigured_game),
        'a sector id from another level never freezes an unconfigured game';

    INSERT INTO doom.actor_types (kind, default_health, radius, attack_range, attack_damage)
    VALUES ('exit sentinel fixture', 30, 8, 48, 25);
    INSERT INTO doom.actor_pursuits (kind, sight_range, move_distance, interval_ticks)
    VALUES ('exit sentinel fixture', 128, 0, 1);
    doomed_game := doom.start_game(test_level, 0, 60, 32);
    INSERT INTO doom.actors (game_id, sector_id, kind, x, y)
    VALUES (doomed_game, 1, 'exit sentinel fixture', 128, 32);
    UPDATE doom.actors SET health = 25 WHERE game_id = doomed_game AND kind = 'player';
    tick_result := doom.tick(doomed_game, p_forward => 1, p_ticks => 4);
    ASSERT tick_result = 4
        AND (SELECT finished_at_tick IS NULL FROM doom.games WHERE game_id = doomed_game)
        AND EXISTS (SELECT FROM doom.actors WHERE game_id = doomed_game AND kind = 'player'
                    AND (x, sector_id, health, animation_start_tick) = (68, 1, 0, 1)),
        'a lethal attack on the arrival tic prevents completion';
END;
$$;

ROLLBACK;
