BEGIN;
SET LOCAL plpgsql.check_asserts = on;

DO $$
DECLARE
    test_level bigint;
    test_game bigint;
    other_game bigint;
    batched_game bigint;
    single_game bigint;
    player doom.actors;
    moved doom.actors;
    closed_frame bytea;
    frame bytea;
    tolerance constant double precision := 0.00002;
BEGIN
    INSERT INTO doom.levels (name) VALUES ('gate test hall') RETURNING level_id INTO test_level;
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height, floor_color)
    VALUES (test_level, 0, 0, 128, 4215976), (test_level, 1, 0, 0, 8719920);
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

    test_game := doom.start_game(test_level, 0, 32, 0);
    other_game := doom.start_game(test_level, 0, -1, 0);
    SELECT * INTO STRICT player FROM doom.actors WHERE game_id = test_game AND kind = 'player';
    moved := doom.move_actor(player, 48, 0, 56, 16);
    ASSERT abs(moved.x - 48) < tolerance AND moved.sector_id = 0, 'a closed gate stops the player body';
    closed_frame := doom.render(test_game, 32, 32);

    PERFORM doom.tick(other_game, p_use => true);
    ASSERT NOT EXISTS (SELECT FROM doom.ceiling_motions WHERE game_id = other_game), 'the control is out of reach at 65 units';
    UPDATE doom.actors SET x = 0, angle = pi() WHERE game_id = other_game AND kind = 'player';
    PERFORM doom.tick(other_game, p_use => true);
    ASSERT NOT EXISTS (SELECT FROM doom.ceiling_motions WHERE game_id = other_game), 'a control behind the player does not activate';
    PERFORM doom.tick(other_game, p_turn => -pi(), p_use => true);
    ASSERT (SELECT ceiling_height FROM doom.sector_state WHERE game_id = other_game AND sector_id = 1) = 24,
        'the use reaches a control exactly 64 units away after turning on that tic';
    ASSERT doom.render(test_game, 32, 32) = closed_frame, 'a game never shares another game''s gate position';

    frame := doom.step(test_game, 32, 32, p_use => true);
    ASSERT frame = doom.render(test_game, 32, 32) AND frame <> closed_frame,
        'the use updates the visible opening in the same RGB response';
    ASSERT (SELECT ceiling_height FROM doom.sector_state WHERE game_id = test_game AND sector_id = 1) = 24,
        'the first use moves the ceiling by one tick';
    ASSERT (SELECT target_height FROM doom.ceiling_motions WHERE game_id = test_game AND sector_id = 1) = 96,
        'an unfinished opening remains scheduled';

    frame := doom.step_spans(test_game, 32, 32);
    ASSERT frame = doom.render_spans(test_game, 32, 32), 'the compact response renders the advanced opening';
    ASSERT (SELECT ceiling_height FROM doom.sector_state WHERE game_id = test_game AND sector_id = 1) = 48,
        'an idle tick continues opening the gate';
    moved := doom.move_actor(player, 48, 0, 56, 16);
    ASSERT abs(moved.x - 48) < tolerance AND moved.sector_id = 0,
        'the low opening is visible before it admits the player body';

    PERFORM doom.tick(test_game);
    moved := doom.move_actor(player, 48, 0, 56, 16);
    ASSERT moved.x = 80 AND moved.sector_id = 1, 'a 72-unit opening admits the 56-unit player';
    PERFORM doom.tick(test_game, p_ticks => 2);
    ASSERT (SELECT ceiling_height FROM doom.sector_state WHERE game_id = test_game AND sector_id = 1) = 96,
        'opening stops at its configured target';
    ASSERT NOT EXISTS (SELECT FROM doom.ceiling_motions WHERE game_id = test_game), 'a finished opening is removed from active motion';

    frame := doom.step_spans(other_game, 32, 32, p_use => true);
    ASSERT (SELECT ceiling_height FROM doom.sector_state WHERE game_id = other_game AND sector_id = 1) = 0
        AND NOT EXISTS (SELECT FROM doom.ceiling_motions WHERE game_id = other_game)
        AND frame = doom.render_spans(other_game, 32, 32),
        'using a control during its opening reverses the pending target';

    INSERT INTO doom.actor_types (kind, default_health, radius, height) VALUES ('gate fixture actor', 20, 0, 72);
    INSERT INTO doom.actors (game_id, sector_id, kind, x, y) VALUES (test_game, 1, 'gate fixture actor', 100, 0);
    PERFORM doom.tick(test_game, p_ticks => 3, p_use => true);
    ASSERT (SELECT ceiling_height FROM doom.sector_state WHERE game_id = test_game AND sector_id = 1) = 72,
        'closing waits at a living actor''s headroom';
    ASSERT (SELECT target_height FROM doom.ceiling_motions WHERE game_id = test_game AND sector_id = 1) = 0,
        'waited closure keeps its target';
    UPDATE doom.actors SET health = 0 WHERE game_id = test_game AND kind = 'gate fixture actor';
    PERFORM doom.tick(test_game, p_ticks => 3);
    ASSERT doom.render(test_game, 32, 32) = closed_frame
        AND NOT EXISTS (SELECT FROM doom.ceiling_motions WHERE game_id = test_game),
        'a SQL health edit releases the closing gate';

    batched_game := doom.start_game(test_level, 0, 32, 0);
    single_game := doom.start_game(test_level, 0, 32, 0);
    PERFORM doom.tick(batched_game, p_forward => 1, p_ticks => 5, p_use => true);
    PERFORM doom.tick(single_game, p_forward => 1, p_use => true);
    FOR tic IN 2..5 LOOP
        PERFORM doom.tick(single_game, p_forward => 1);
    END LOOP;
    SELECT * INTO STRICT player FROM doom.actors WHERE game_id = batched_game AND kind = 'player';
    SELECT * INTO STRICT moved FROM doom.actors WHERE game_id = single_game AND kind = 'player';
    ASSERT player.sector_id = 1
        AND (player.x, player.y, player.z, player.angle, player.sector_id) =
            (moved.x, moved.y, moved.z, moved.angle, moved.sector_id)
        AND doom.render(batched_game, 32, 32) = doom.render(single_game, 32, 32),
        'one press during a batch is equivalent to a single press and successive movement tics';
    ASSERT (SELECT ceiling_height FROM doom.sector_state WHERE game_id = batched_game AND sector_id = 1) = 96,
        'a held batch only schedules the gate once';

    UPDATE doom.actors SET x = 68, angle = pi() WHERE game_id = batched_game AND kind = 'player';
    PERFORM doom.tick(batched_game, p_forward => 1, p_ticks => 4, p_use => true);
    ASSERT (SELECT sector_id FROM doom.actors WHERE game_id = batched_game AND kind = 'player') = 0
        AND (SELECT ceiling_height FROM doom.sector_state WHERE game_id = batched_game AND sector_id = 1) = 0,
        'the closing gate uses the player''s current sector within a movement batch';

    UPDATE doom.actors SET x = 32, sector_id = 0 WHERE game_id = single_game AND kind = 'player';
    UPDATE doom.sector_state SET floor_height = 12 WHERE game_id = single_game AND sector_id = 1;
    PERFORM doom.tick(single_game, p_ticks => 4, p_use => true);
    ASSERT EXISTS (SELECT FROM doom.sector_state WHERE game_id = single_game AND sector_id = 1
                   AND floor_height = 12 AND ceiling_height = 12)
        AND NOT EXISTS (SELECT FROM doom.ceiling_motions WHERE game_id = single_game),
        'a raw SQL floor change limits the gate ceiling at its closed position';

    UPDATE doom.actors SET x = 32 WHERE game_id = other_game AND kind = 'player';
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id)
    VALUES (test_level, 7, 48, 16, 48, -16, 0);
    PERFORM doom.tick(other_game, p_use => true);
    ASSERT NOT EXISTS (SELECT FROM doom.ceiling_motions WHERE game_id = other_game), 'a nearer wall hides the control';

    UPDATE doom.lines SET x1 = 64, x2 = 64, y1 = 64, y2 = 0 WHERE level_id = test_level AND line_id = 7;
    UPDATE doom.lines SET y1 = 0 WHERE level_id = test_level AND line_id = 0;
    PERFORM doom.tick(other_game, p_use => true);
    ASSERT NOT EXISTS (SELECT FROM doom.ceiling_motions WHERE game_id = other_game),
        'a wall meeting a control at the same distance still occludes the control';

    DELETE FROM doom.lines WHERE level_id = test_level AND line_id = 7;
    UPDATE doom.lines SET y1 = 64 WHERE level_id = test_level AND line_id = 0;
    UPDATE doom.actors SET health = 0 WHERE game_id = other_game AND kind = 'player';
    PERFORM doom.tick(other_game, p_use => true);
    ASSERT NOT EXISTS (SELECT FROM doom.ceiling_motions WHERE game_id = other_game), 'a dead player cannot activate a gate';

    UPDATE doom.actors SET health = 100 WHERE game_id = other_game AND kind = 'player';
    BEGIN
        PERFORM doom.step(other_game, 0, 32, p_use => true);
        RAISE EXCEPTION 'expected the composed call to reject zero width';
    EXCEPTION WHEN invalid_parameter_value THEN
        NULL;
    END;
    ASSERT (SELECT ceiling_height FROM doom.sector_state WHERE game_id = other_game AND sector_id = 1) = 0
        AND NOT EXISTS (SELECT FROM doom.ceiling_motions WHERE game_id = other_game),
        'a failed frame rolls back the scheduled gate and its first movement tic';

    UPDATE doom.actors SET angle = 1e-310 WHERE game_id = other_game AND kind = 'player';
    PERFORM doom.tick(other_game, p_use => true);
    ASSERT (SELECT ceiling_height FROM doom.sector_state WHERE game_id = other_game AND sector_id = 1) = 24,
        'a nearly parallel wall does not disrupt the control ray';
END;
$$;

ROLLBACK;
