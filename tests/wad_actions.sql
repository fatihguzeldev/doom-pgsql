\set ON_ERROR_STOP on
BEGIN;
SET LOCAL plpgsql.check_asserts = on;

DO $$
DECLARE
    test_level bigint;
    game bigint;
    other_game bigint;
    observed_tick bigint;
BEGIN
    INSERT INTO doom.levels (name) VALUES ('Imported action fixture') RETURNING level_id INTO test_level;
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height)
    VALUES (test_level, 0, 0, 96), (test_level, 1, 0, 0), (test_level, 2, 0, 96),
           (test_level, 3, 32, 96);
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id, back_sector_id)
    VALUES (test_level, 0, 64, 64, 64, 0, 0, 1),
           (test_level, 1, 96, 64, 96, 0, 1, 2),
           (test_level, 2, 160, 64, 160, 0, 2, NULL),
           (test_level, 3, 40, 48, 40, 16, 0, 0),
           (test_level, 4, 132, 48, 132, 16, 2, 2),
           (test_level, 5, 112, 16, 112, 0, 2, 3),
           (test_level, 6, 108, 48, 108, 16, 2, 2);
    INSERT INTO doom.wad_line_actions (level_id, line_id, special, tag)
    VALUES (test_level, 0, 33, 0), (test_level, 2, 11, 0), (test_level, 3, 11, 0),
           (test_level, 4, 124, 0), (test_level, 6, 62, 17);
    INSERT INTO doom.wad_sector_properties (level_id, sector_id, special, tag)
    VALUES (test_level, 3, 0, 17);
    PERFORM doom._bind_wad_actions(test_level);

    game := doom.start_game(test_level, 0, 48, 32);
    observed_tick := doom.tick(game, p_use => true);
    ASSERT observed_tick = 1 AND NOT EXISTS (
        SELECT FROM doom.sector_state WHERE game_id = game AND sector_id = 1
    ), 'a locked action waits for its corresponding key';
    INSERT INTO doom.game_keys (game_id, key_kind) VALUES (game, 'red');
    observed_tick := doom.tick(game, p_use => true, p_ticks => 48);
    ASSERT observed_tick = 49 AND (
        SELECT ceiling_height FROM doom.sector_state WHERE game_id = game AND sector_id = 1
    ) = 92, 'a real key activates a door toward adjacent ceiling clearance';
    observed_tick := doom.tick(game, p_use => true);
    ASSERT observed_tick = 50 AND NOT EXISTS (
        SELECT FROM doom.ceiling_motions WHERE game_id = game
    ), 'using a consumed action cannot close a permanent door';
    ASSERT doom.tick(game, p_forward => 1, p_ticks => 7) = 57, 'the opened gate is traversable';
    observed_tick := doom.tick(game, p_use => true);
    ASSERT observed_tick = 58 AND (
        SELECT floor_height FROM doom.sector_state WHERE game_id = game AND sector_id = 3
    ) < 32, 'a use switch moves its tagged platform instead of hitting the farther exit';
    observed_tick := doom.tick(game, p_forward => 1, p_ticks => 12);
    ASSERT observed_tick = 62 AND (
        SELECT exit_kind FROM doom.games WHERE game_id = game
    ) = 'secret', 'a self-referencing walkover trigger takes effect on its crossing tic';

    other_game := doom.start_game(test_level, 2, 116, 54);
    observed_tick := doom.tick(other_game, p_use => true, p_ticks => 6);
    ASSERT observed_tick = 1 AND (
        SELECT exit_kind FROM doom.games WHERE game_id = other_game
    ) = 'normal', 'a separate game can activate a one-sided exit switch';
    ASSERT NOT EXISTS (SELECT FROM doom.line_activations WHERE game_id = other_game AND line_id = 0),
        'one-shot state belongs to each game';
END;
$$;

DO $$
DECLARE
    test_level bigint;
    game bigint;
    observed_tick bigint;
BEGIN
    INSERT INTO doom.levels (name) VALUES ('Warp and hazard fixture') RETURNING level_id INTO test_level;
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height)
    VALUES (test_level, 0, 0, 96), (test_level, 1, 8, 96);
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id, back_sector_id)
    VALUES (test_level, 0, 64, 64, 64, 0, 0, 0),
           (test_level, 1, 200, 0, 200, 64, 1, NULL),
           (test_level, 2, 200, 64, 300, 64, 1, NULL),
           (test_level, 3, 300, 64, 300, 0, 1, NULL),
           (test_level, 4, 300, 0, 200, 0, 1, NULL);
    INSERT INTO doom.wad_line_actions (level_id, line_id, special, tag) VALUES (test_level, 0, 97, 8);
    INSERT INTO doom.wad_sector_properties (level_id, sector_id, special, tag) VALUES (test_level, 1, 11, 8);
    INSERT INTO doom.level_things (level_id, thing_id, x, y, angle_deg, type_code, flags)
    VALUES (test_level, 0, 240, 32, 180, 14, 7);
    PERFORM doom._bind_wad_actions(test_level);

    game := doom.start_game(test_level, 0, 56, 32);
    observed_tick := doom.tick(game, p_forward => 1, p_ticks => 2);
    ASSERT observed_tick = 2 AND EXISTS (
        SELECT FROM doom.actors WHERE game_id = game AND sector_id = 1
          AND x = 240 AND y = 32 AND z = 8 AND angle = pi()
    ), 'a walkover warp resolves its tagged destination and angle from the archive';
    UPDATE doom.actors SET health = 25 WHERE game_id = game AND kind = 'player';
    observed_tick := doom.tick(game, p_ticks => 128);
    ASSERT observed_tick = 32 AND EXISTS (
        SELECT FROM doom.games WHERE game_id = game AND finished_at_tick = 32 AND exit_kind = 'normal'
    ) AND (SELECT health FROM doom.actors WHERE game_id = game AND kind = 'player') = 5,
        'an exit hazard acts on the world clock, including while the player is idle';

    UPDATE doom.wad_sector_properties SET special = 5 WHERE level_id = test_level AND sector_id = 1;
    game := doom.start_game(test_level, 1, 240, 32);
    INSERT INTO doom.game_inventory (game_id, item_kind, amount) VALUES (game, 'hazard-protection', 1);
    PERFORM doom.tick(game, p_ticks => 64);
    ASSERT (SELECT health FROM doom.actors WHERE game_id = game AND kind = 'player') = 90
        AND NOT EXISTS (SELECT FROM doom.game_inventory WHERE game_id = game AND item_kind = 'hazard-protection'),
        'a hazard protection charge blocks one damage event only';
END;
$$;

ROLLBACK;
