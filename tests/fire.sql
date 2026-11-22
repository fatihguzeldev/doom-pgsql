BEGIN;
SET LOCAL plpgsql.check_asserts = on;

DO $$
DECLARE
    firing_level bigint;
    firing_game bigint;
    other_game bigint;
    wide_target bigint;
BEGIN
    INSERT INTO doom.levels (name) VALUES ('target selection fixture') RETURNING level_id INTO firing_level;
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height)
    VALUES (firing_level, 0, 0, 128);
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id)
    VALUES (firing_level, 0, -96, -64, -96, 64, 0), (firing_level, 1, 160, 64, 160, -64, 0);
    UPDATE doom.actor_types SET attack_range = 43, attack_damage = 13 WHERE kind = 'player';
    INSERT INTO doom.actor_types (kind, default_health, radius, height, blocks_actors)
    VALUES ('ray narrow fixture', 40, 4, 56, false), ('ray wide fixture', 40, 20, 56, false);

    firing_game := doom.start_game(firing_level, 0, 0, 0, pi());
    other_game := doom.start_game(firing_level, 0, 0, 0);
    INSERT INTO doom.actors (game_id, sector_id, kind, x, y, z)
    VALUES (firing_game, 0, 'ray wide fixture', 63, 0, 0) RETURNING actor_id INTO wide_target;
    INSERT INTO doom.actors (game_id, sector_id, kind, x, y, z, health)
    VALUES (firing_game, 0, 'ray narrow fixture', 50, 0, 0, 40),
           (firing_game, 0, 'ray wide fixture', 63, 0, 0, 40),
           (firing_game, 0, 'ray narrow fixture', 12, 8, 0, 40),
           (firing_game, 0, 'ray narrow fixture', 16, 0, 42, 40),
           (firing_game, 0, 'ray narrow fixture', 18, 0, -15, 40),
           (firing_game, 0, 'ray narrow fixture', 20, 0, 0, 0),
           (other_game, 0, 'ray narrow fixture', 15, 0, 0, 40);

    PERFORM doom.tick(firing_game, p_fire => true);
    ASSERT (SELECT health FROM doom.actors WHERE game_id = firing_game AND actor_id = wide_target) = 40,
        'an actor behind the player cannot be hit';

    PERFORM doom.tick(firing_game, p_turn => -pi(), p_fire => true);
    ASSERT (SELECT health FROM doom.actors WHERE game_id = firing_game AND actor_id = wide_target) = 27,
        'a shot after turning reaches the cylinder edge at the exact range limit';

    UPDATE doom.actor_types SET attack_range = 64 WHERE kind = 'player';
    PERFORM doom.tick(firing_game, p_forward => 0.125, p_ticks => 3, p_fire => true);
    ASSERT EXISTS (SELECT FROM doom.actors WHERE game_id = firing_game AND actor_id = wide_target
                   AND health = 14 AND animation_start_tick = 0),
        'one press in a batch damages the nearest edge once and preserves the live animation';
    ASSERT NOT EXISTS (SELECT FROM doom.actors WHERE game_id IN (firing_game, other_game)
                       AND actor_id <> wide_target AND kind <> 'player'
                       AND health <> CASE WHEN x = 20 THEN 0 ELSE 40 END),
        'off-ray, higher, lower, dead, equally near and other-game actors take no damage';
    ASSERT (SELECT health FROM doom.actors WHERE game_id = firing_game AND kind = 'player') = 100,
        'the firing player never hits their own body';

    UPDATE doom.actors SET health = 0 WHERE game_id = firing_game AND kind = 'player';
    PERFORM doom.tick(firing_game, p_fire => true);
    ASSERT (SELECT health FROM doom.actors WHERE game_id = firing_game AND actor_id = wide_target) = 14,
        'a dead player cannot fire';

    UPDATE doom.actors SET angle = '5e-324'::double precision WHERE game_id = other_game AND kind = 'player';
    INSERT INTO doom.actors (game_id, sector_id, kind, x, y)
    VALUES (other_game, 0, 'ray narrow fixture', 0.125, 0);
    PERFORM doom.tick(other_game, p_fire => true);
    ASSERT (SELECT health FROM doom.actors WHERE game_id = other_game AND x = 0.125) = 27,
        'a nearly axis-aligned shot still hits a nearby actor';
END;
$$;

DO $$
DECLARE
    firing_level bigint;
    firing_game bigint;
    compact_game bigint;
    distant_target bigint;
    wall_target bigint;
    moving_blocker bigint;
    firing_tick bigint;
    frame bytea;
    previous_frame bytea;
BEGIN
    INSERT INTO doom.levels (name) VALUES ('three room shot fixture') RETURNING level_id INTO firing_level;
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height)
    VALUES (firing_level, 0, 0, 128), (firing_level, 1, 0, 128), (firing_level, 2, 0, 128);
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id, back_sector_id, wall_color)
    VALUES (firing_level, 0, 64, 64, 64, -64, 0, 1, 10052948),
           (firing_level, 1, 112, 64, 112, -64, 1, 2, 7832175),
           (firing_level, 2, 184, 64, 184, -64, 2, NULL, 4939618);
    INSERT INTO doom.gates (level_id, sector_id, closed_ceiling, open_ceiling, units_per_tick)
    VALUES (firing_level, 1, 41, 96, 8);
    INSERT INTO doom.gate_controls (level_id, line_id, sector_id) VALUES (firing_level, 0, 1);
    UPDATE doom.actor_types SET attack_range = 150, attack_damage = 13 WHERE kind = 'player';
    INSERT INTO doom.actor_types (kind, default_health, radius, height)
    VALUES ('ray blocker fixture', 26, 8, 56), ('ray wall fixture', 26, 5, 56);

    firing_game := doom.start_game(firing_level, 0, 16, 0);
    INSERT INTO doom.actors (game_id, sector_id, kind, x, y)
    VALUES (firing_game, 2, 'ray blocker fixture', 140, 0) RETURNING actor_id INTO distant_target;
    INSERT INTO doom.sector_state (game_id, level_id, sector_id, floor_height, ceiling_height)
    VALUES (firing_game, firing_level, 1, 0, 41);
    PERFORM doom.tick(firing_game, p_fire => true);
    ASSERT (SELECT health FROM doom.actors WHERE game_id = firing_game AND actor_id = distant_target) = 26,
        'a portal ceiling exactly at eye level blocks the shot';

    UPDATE doom.sector_state SET floor_height = 42, ceiling_height = 96
    WHERE game_id = firing_game AND sector_id = 1;
    PERFORM doom.tick(firing_game, p_fire => true);
    ASSERT (SELECT health FROM doom.actors WHERE game_id = firing_game AND actor_id = distant_target) = 26,
        'a floor above eye level blocks the shot';

    UPDATE doom.sector_state SET floor_height = 41 WHERE game_id = firing_game AND sector_id = 1;
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id)
    VALUES (firing_level, 3, 37, 64, 37, -64, 0);
    -- The 3-4-5 chord touches x = 37, where converting the wall fraction rounds upward.
    INSERT INTO doom.actors (game_id, sector_id, kind, x, y)
    VALUES (firing_game, 0, 'ray wall fixture', 41, 3) RETURNING actor_id INTO wall_target;
    PERFORM doom.tick(firing_game, p_fire => true);
    ASSERT NOT EXISTS (SELECT FROM doom.actors WHERE game_id = firing_game
                       AND actor_id IN (wall_target, distant_target) AND health <> 26),
        'an opaque wall wins at its exact intersection and covers the actor farther behind';
    UPDATE doom.actors SET x = 40.999999 WHERE game_id = firing_game AND actor_id = wall_target;
    PERFORM doom.tick(firing_game, p_fire => true);
    ASSERT (SELECT health FROM doom.actors WHERE game_id = firing_game AND actor_id = wall_target) = 13,
        'a cylinder intersection just before the wall still takes damage';
    DELETE FROM doom.lines WHERE level_id = firing_level AND line_id = 3;
    DELETE FROM doom.actors WHERE game_id = firing_game AND actor_id = wall_target;

    PERFORM doom.tick(firing_game, p_fire => true);
    ASSERT (SELECT health FROM doom.actors WHERE game_id = firing_game AND actor_id = distant_target) = 13,
        'an eye-level floor permits a shot through both portals';

    UPDATE doom.sector_state SET floor_height = 0, ceiling_height = 41
    WHERE game_id = firing_game AND sector_id = 1;
    SELECT tick_number + 1 INTO STRICT firing_tick FROM doom.games WHERE game_id = firing_game;
    previous_frame := doom.render(firing_game, 32, 32);
    frame := doom.step(firing_game, 32, 32, p_ticks => 4, p_use => true, p_fire => true);
    ASSERT EXISTS (SELECT FROM doom.actors WHERE game_id = firing_game AND actor_id = distant_target
                   AND health = 0 AND animation_start_tick = firing_tick),
        'use opens the shot path on its first tic and death starts at that tic in a batch';
    ASSERT frame = doom.render(firing_game, 32, 32) AND frame <> previous_frame,
        'the RGB response uses the post-shot state';

    compact_game := doom.start_game(firing_level, 0, 0, 0);
    INSERT INTO doom.actors (game_id, sector_id, kind, x, y, health)
    VALUES (compact_game, 0, 'ray blocker fixture', 26, 0, 13) RETURNING actor_id INTO moving_blocker;
    BEGIN
        PERFORM doom.step(compact_game, 0, 32, p_forward => 1, p_fire => true);
        RAISE EXCEPTION 'expected the frame to reject zero width';
    EXCEPTION WHEN invalid_parameter_value THEN
        NULL;
    END;
    ASSERT EXISTS (SELECT FROM doom.actors WHERE game_id = compact_game AND actor_id = moving_blocker
                   AND health = 13 AND animation_start_tick = 0)
        AND (SELECT tick_number FROM doom.games WHERE game_id = compact_game) = 0
        AND (SELECT x FROM doom.actors WHERE game_id = compact_game AND kind = 'player') = 0,
        'a failed render rolls back shot damage, movement and the tick';

    frame := doom.step_spans(compact_game, 32, 32, p_forward => 1, p_fire => true);
    ASSERT (SELECT health FROM doom.actors WHERE game_id = compact_game AND actor_id = moving_blocker) = 0
        AND (SELECT x FROM doom.actors WHERE game_id = compact_game AND kind = 'player') = 8,
        'the compact step kills the blocker before attempting movement';
    ASSERT frame = doom.render_spans(compact_game, 32, 32), 'the compact response uses the post-shot state';
END;
$$;

ROLLBACK;
