BEGIN;
SET LOCAL plpgsql.check_asserts = on;

DO $$
DECLARE
    test_level bigint;
    batched_game bigint;
    replay_game bigint;
    rollback_game bigint;
    batched_player doom.actors;
    replayed_player doom.actors;
    idle constant doom.input_command := ROW(0, 0, 0, 1, false, false);
    press constant doom.input_command := ROW(0.5, 0, 0, 1, true, true);
    turn_right constant doom.input_command := ROW(0, 0, 0.25, 1, false, false);
    inputs doom.input_command[] := array_fill(idle, ARRAY[6], ARRAY[-3]);
    invalid record;
    frame bytea;
BEGIN
    INSERT INTO doom.levels (name) VALUES ('input replay hall') RETURNING level_id INTO test_level;
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height)
    VALUES (test_level, 0, 0, 128), (test_level, 1, 0, 0);
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id, back_sector_id)
    VALUES (test_level, 0, 64, 64, 64, -64, 0, 1),
           (test_level, 1, -96, -64, -96, 64, 0, NULL),
           (test_level, 2, -96, 64, 64, 64, 0, NULL),
           (test_level, 3, 64, -64, -96, -64, 0, NULL),
           (test_level, 4, 64, 64, 160, 64, 1, NULL),
           (test_level, 5, 160, 64, 160, -64, 1, NULL),
           (test_level, 6, 160, -64, 64, -64, 1, NULL);
    INSERT INTO doom.gates (level_id, sector_id, closed_ceiling, open_ceiling, units_per_tick)
    VALUES (test_level, 1, 0, 96, 24);
    INSERT INTO doom.gate_controls (level_id, line_id, sector_id) VALUES (test_level, 0, 1);
    INSERT INTO doom.actor_types (kind, default_health, radius, blocks_actors)
    VALUES ('input target fixture', 40, 4, false);

    batched_game := doom.start_game(test_level, 0, 12, 0);
    replay_game := doom.start_game(test_level, 0, 12, 0);
    rollback_game := doom.start_game(test_level, 0, 12, 0);
    INSERT INTO doom.actors (game_id, sector_id, kind, x, y)
    VALUES (batched_game, 0, 'input target fixture', 55, 0),
           (replay_game, 0, 'input target fixture', 55, 0),
           (rollback_game, 0, 'input target fixture', 55, 0);

    inputs[-3] := press;
    inputs[-2] := ROW(0.5, 0, 0, 2, false, false);
    inputs[-1] := ROW(0.5, 0, 0, 1, false, false);
    inputs[0] := press;
    inputs[1] := turn_right;
    inputs[2] := ROW(0, 0.5, 0, 1, false, false);
    frame := doom.step_inputs(batched_game, 8, 2, inputs);

    PERFORM doom.tick(replay_game, p_forward => 0.5, p_use => true, p_fire => true);
    PERFORM doom.tick(replay_game, p_forward => 0.5, p_ticks => 2);
    PERFORM doom.tick(replay_game, p_forward => 0.5);
    PERFORM doom.tick(replay_game, p_forward => 0.5, p_use => true, p_fire => true);
    PERFORM doom.tick(replay_game, p_turn => 0.25);
    PERFORM doom.tick(replay_game, p_strafe => 0.5);

    SELECT * INTO STRICT batched_player FROM doom.actors WHERE game_id = batched_game AND kind = 'player';
    SELECT * INTO STRICT replayed_player FROM doom.actors WHERE game_id = replay_game AND kind = 'player';
    ASSERT (batched_player.x, batched_player.y, batched_player.z, batched_player.angle,
            batched_player.sector_id, batched_player.health) = (replayed_player.x, replayed_player.y,
            replayed_player.z, replayed_player.angle, replayed_player.sector_id, replayed_player.health)
        AND (SELECT tick_number FROM doom.games WHERE game_id = batched_game) = 7,
        'ordered controls with a negative lower bound produce the exact replay pose and clock';
    ASSERT (SELECT count(*) FROM doom.actors WHERE game_id IN (batched_game, replay_game)
            AND kind = 'input target fixture' AND health = 0 AND animation_start_tick = 5) = 2,
        'both fire presses survive coalescing and the second takes effect on tic five';
    ASSERT (SELECT count(*) FROM doom.sector_state WHERE game_id IN (batched_game, replay_game)
            AND sector_id = 1 AND ceiling_height = 24) = 2
        AND (SELECT count(*) FROM doom.ceiling_motions WHERE game_id IN (batched_game, replay_game)
             AND sector_id = 1 AND target_height = 0) = 2,
        'the second use press starts closing the gate on tic five';
    ASSERT frame = doom.render_compact(replay_game, 8, 2)
        AND frame = '\x00'::bytea || doom.render(replay_game, 8, 2),
        'the combined call returns the exact tagged RGB frame of the final pose';

    FOR invalid IN
        SELECT * FROM (VALUES
            ('null array', NULL::doom.input_command[]),
            ('empty array', ARRAY[]::doom.input_command[]),
            ('two dimensions', ARRAY[[idle, idle]]),
            ('excess command count', array_fill(idle, ARRAY[129])),
            ('excess total ticks', ARRAY[ROW(0, 0, 0, 127, false, false)::doom.input_command,
                                        ROW(0, 1, 0, 2, false, false)::doom.input_command]),
            ('null element after actions', ARRAY[press, turn_right, NULL]),
            ('null forward', ARRAY[ROW(NULL, 0, 0, 1, false, false)::doom.input_command]),
            ('null strafe', ARRAY[ROW(0, NULL, 0, 1, false, false)::doom.input_command]),
            ('null turn', ARRAY[ROW(0, 0, NULL, 1, false, false)::doom.input_command]),
            ('null ticks', ARRAY[ROW(0, 0, 0, NULL, false, false)::doom.input_command]),
            ('null use', ARRAY[ROW(0, 0, 0, 1, NULL, false)::doom.input_command]),
            ('null fire', ARRAY[ROW(0, 0, 0, 1, false, NULL)::doom.input_command]),
            ('out of range forward', ARRAY[ROW(2, 0, 0, 1, false, false)::doom.input_command]),
            ('nonfinite strafe', ARRAY[ROW(0, 'NaN'::double precision, 0, 1, false, false)::doom.input_command]),
            ('out of range turn', ARRAY[ROW(0, 0, -4, 1, false, false)::doom.input_command]),
            ('zero ticks', ARRAY[ROW(0, 0, 0, 0, false, false)::doom.input_command])
        ) AS validation_cases(label, commands)
    LOOP
        BEGIN
            PERFORM doom.tick_inputs(rollback_game, invalid.commands);
            RAISE EXCEPTION 'expected invalid input rejection for %', invalid.label;
        EXCEPTION WHEN invalid_parameter_value THEN
            NULL;
        END;
    END LOOP;

    BEGIN
        PERFORM doom.step_inputs(rollback_game, 0, 4, ARRAY[press, turn_right]);
        RAISE EXCEPTION 'expected the combined call to reject zero width';
    EXCEPTION WHEN invalid_parameter_value THEN
        NULL;
    END;
    ASSERT (SELECT tick_number FROM doom.games WHERE game_id = rollback_game) = 0
        AND EXISTS (SELECT FROM doom.actors WHERE game_id = rollback_game AND kind = 'player'
                    AND (x, y, angle) = (12, 0, 0))
        AND EXISTS (SELECT FROM doom.actors WHERE game_id = rollback_game AND kind = 'input target fixture'
                    AND health = 40 AND animation_start_tick = 0)
        AND NOT EXISTS (SELECT FROM doom.sector_state WHERE game_id = rollback_game)
        AND NOT EXISTS (SELECT FROM doom.ceiling_motions WHERE game_id = rollback_game),
        'malformed late input and invalid frame dimensions roll back clock, pose, damage and gate state';
    ASSERT doom.tick_inputs(rollback_game, array_fill(idle, ARRAY[128])) = 128,
        'exactly 128 commands and 128 tics fit in one batch';
END;
$$;

DO $$
DECLARE
    test_level bigint;
    test_game bigint;
    tick_result bigint;
    advance constant doom.input_command := ROW(1, 0, 0, 6, false, false);
    retreat constant doom.input_command := ROW(-1, 0, 0.25, 5, true, true);
    malformed constant doom.input_command := ROW(0, 0, 0, 0, false, false);
BEGIN
    INSERT INTO doom.levels (name) VALUES ('input exit hall') RETURNING level_id INTO test_level;
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
    test_game := doom.start_game(test_level, 0, 52, 32);

    BEGIN
        PERFORM doom.tick_inputs(test_game, ARRAY[advance, retreat, malformed]);
        RAISE EXCEPTION 'expected malformed input after reaching the exit to be rejected';
    EXCEPTION WHEN invalid_parameter_value THEN
        NULL;
    END;
    ASSERT EXISTS (SELECT FROM doom.games WHERE game_id = test_game AND tick_number = 0 AND finished_at_tick IS NULL)
        AND (SELECT x FROM doom.actors WHERE game_id = test_game AND kind = 'player') = 52,
        'a malformed trailing command rolls back completion and movement';

    tick_result := doom.tick_inputs(test_game, ARRAY[advance, retreat]);
    ASSERT tick_result = 2
        AND (SELECT finished_at_tick FROM doom.games WHERE game_id = test_game) = 2
        AND EXISTS (SELECT FROM doom.actors WHERE game_id = test_game AND kind = 'player'
                    AND (x, y, angle, sector_id) = (68, 32, 0, 1)),
        'valid trailing controls leave the player and clock at the first exit tic';

    BEGIN
        PERFORM doom.tick_inputs(test_game, ARRAY[retreat, malformed]);
        RAISE EXCEPTION 'expected a finished game to reject malformed input';
    EXCEPTION WHEN invalid_parameter_value THEN
        NULL;
    END;
    ASSERT doom.tick_inputs(test_game, ARRAY[retreat]) = 2,
        'valid input on a previously finished game returns its frozen clock';
END;
$$;

ROLLBACK;
