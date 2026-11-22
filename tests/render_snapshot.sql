BEGIN;
SET LOCAL plpgsql.check_asserts = on;

DO $$
DECLARE
    test_campaign bigint;
    first_level bigint;
    next_level bigint;
    first_game bigint;
    next_game bigint;
    target_actor bigint;
    snapshot record;
    live_frame bytea;
BEGIN
    INSERT INTO doom.wad_campaigns DEFAULT VALUES RETURNING campaign_id INTO test_campaign;
    INSERT INTO doom.levels (name) VALUES ('snapshot room') RETURNING level_id INTO first_level;
    INSERT INTO doom.levels (name) VALUES ('snapshot next room') RETURNING level_id INTO next_level;
    INSERT INTO doom.wad_campaign_levels (campaign_id, episode, map_number, level_id)
    VALUES (test_campaign, 0, 1, first_level), (test_campaign, 0, 2, next_level);

    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height, light_level, floor_color)
    VALUES (first_level, 0, 0, 64, 255, 8947848), (next_level, 0, 0, 64, 255, 1056816);
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id)
    SELECT level_id, wall.line_id, wall.x1, wall.y1, wall.x2, wall.y2, 0
    FROM unnest(ARRAY[first_level, next_level]) AS level(level_id)
    CROSS JOIN (VALUES
        (0, 0, 0, 0, 64), (1, 0, 64, 64, 64), (2, 64, 64, 64, 0), (3, 64, 0, 0, 0)
    ) AS wall(line_id, x1, y1, x2, y2);
    INSERT INTO doom.level_things (level_id, thing_id, x, y, angle_deg, type_code, flags)
    VALUES (first_level, 0, 16, 32, 0, 1, 7), (next_level, 0, 16, 32, 0, 1, 7);

    first_game := doom.start_wad_campaign(test_campaign);
    INSERT INTO doom.actor_types (kind, default_health, radius, color)
    VALUES ('snapshot target', 20, 8, 16711935);
    INSERT INTO doom.actors (game_id, sector_id, kind, x, y)
    VALUES (first_game, 0, 'snapshot target', 38, 32) RETURNING actor_id INTO target_actor;

    PERFORM doom.tick(first_game, p_ticks => 3);
    SELECT * INTO STRICT snapshot FROM doom.render_snapshot(first_game, 7, 9);
    live_frame := snapshot.frame;
    ASSERT snapshot.game_id = first_game AND snapshot.tick_number = 3
        AND live_frame IS NOT DISTINCT FROM doom.render_compact(first_game, 7, 9),
        'the default snapshot returns one tagged compact frame';

    UPDATE doom.actors SET health = 0 WHERE game_id = first_game AND actor_id = target_actor;
    SELECT * INTO STRICT snapshot FROM doom.render_snapshot(first_game, 7, 9);
    ASSERT snapshot.tick_number = 3 AND snapshot.frame IS DISTINCT FROM live_frame
        AND snapshot.frame IS NOT DISTINCT FROM doom.render_compact(first_game, 7, 9),
        'direct actor updates change the frame without advancing the tick';

    UPDATE doom.games SET finished_at_tick = tick_number, exit_kind = 'normal' WHERE game_id = first_game;
    next_game := doom.advance_wad_campaign(first_game);
    ASSERT next_game IS NOT NULL AND next_game <> first_game,
        'the campaign advances to a separate game identity';
    SELECT * INTO STRICT snapshot FROM doom.render_snapshot(next_game, 7, 9, true);
    ASSERT snapshot.game_id = next_game AND snapshot.tick_number = 0
        AND snapshot.frame IS NOT DISTINCT FROM doom.render_columns(next_game, 7, 9),
        'the next map has its own initial tick and column-ordered frame';
    SELECT * INTO STRICT snapshot FROM doom.render_snapshot(first_game, 7, 9);
    ASSERT snapshot.game_id = first_game AND snapshot.tick_number = 3,
        'a render request for the finished game retains that game identity';

    BEGIN
        PERFORM result.game_id FROM doom.render_snapshot(-1, 7, 9) AS result;
        RAISE EXCEPTION 'expected missing camera error';
    EXCEPTION WHEN no_data_found THEN
        ASSERT SQLERRM = 'game -1 has no player camera';
    END;

    BEGIN
        PERFORM result.game_id FROM doom.render_snapshot(first_game, 0, 9) AS result;
        RAISE EXCEPTION 'expected invalid frame dimensions error';
    EXCEPTION WHEN invalid_parameter_value THEN
        ASSERT SQLERRM = 'frame dimensions must be 1 to 4096 with at most 1048576 pixels';
    END;
END;
$$;

ROLLBACK;
