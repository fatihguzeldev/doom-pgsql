BEGIN;
SET LOCAL plpgsql.check_asserts = on;

DO $$
DECLARE
    test_level bigint;
    other_level bigint;
    test_game bigint;
    other_game bigint;
    easy_game bigint;
    hard_game bigint;
    player doom.actors;
    archive bytea := '\x50574144020000001e030000'::bytea
        || decode(repeat('102030', 256), 'hex')
        || '\x01000100000000000c0000000001001100ff'::bytea
        || '\x0c00000000030000504c415950414c000c030000120000005354494d41300000'::bytea;
BEGIN
    INSERT INTO doom.levels (name) VALUES ('automatic marker fixture') RETURNING level_id INTO test_level;
    INSERT INTO doom.levels (name) VALUES ('second automatic marker fixture') RETURNING level_id INTO other_level;
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height)
    VALUES (test_level, 0, 0, 96), (other_level, 0, 0, 96);
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id)
    SELECT level_id, segment.id, segment.x1, segment.y1, segment.x2, segment.y2, 0
    FROM unnest(ARRAY[test_level, other_level]) AS level(level_id)
    CROSS JOIN (VALUES (0, 0, 0, 0, 64), (1, 0, 64, 160, 64), (2, 160, 64, 160, 0),
                       (3, 160, 0, 0, 0)) AS segment(id, x1, y1, x2, y2);
    INSERT INTO doom.actor_types (kind, default_health) VALUES ('manual marker override', 7);
    INSERT INTO doom.level_actor_bindings (level_id, type_code, kind)
    VALUES (test_level, 2035, 'manual marker override');
    INSERT INTO doom.level_things (level_id, thing_id, x, y, angle_deg, type_code, flags)
    VALUES (test_level, 0, 16, 32, 0, 1, 0),
           (test_level, 1, 18, 32, 0, 5, 2),
           (test_level, 2, 21, 32, 0, 2007, 7),
           (test_level, 3, 24, 32, 0, 2011, 2),
           (test_level, 4, 128, 32, 90, 3004, 1),
           (test_level, 5, 130, 36, 90, 3004, 2),
           (test_level, 6, 132, 40, 90, 3004, 4),
           (test_level, 7, 134, 44, 90, 3004, 18),
           (test_level, 8, 80, 48, 0, 2035, 0),
           (test_level, 9, 88, 48, 0, 14, 7),
           (test_level, 10, 96, 48, 0, 61000, 2),
           (test_level, 11, 96, 48, 0, 61000, 2),
           (test_level, 12, 96, 48, 0, 61001, 18),
           (other_level, 0, 16, 32, 0, 1, 0),
           (other_level, 1, 20, 32, 0, 2011, 7);

    PERFORM doom._bind_wad_actors(test_level, archive);
    PERFORM doom._bind_wad_actors(test_level, archive);
    -- A map without sprite resources still receives the runtime bindings.
    PERFORM doom._bind_wad_actors(other_level, '\x50574144000000000c000000'::bytea);

    ASSERT (SELECT array_agg(kind ORDER BY type_code) FROM doom.level_actor_bindings WHERE level_id = test_level)
        = ARRAY['wad thing 5', 'wad thing 2007', 'wad thing 2011', 'manual marker override', 'wad thing 3004'],
        'binding is idempotent and keeps explicit per-level overrides';
    ASSERT EXISTS (SELECT FROM doom.level_materials WHERE level_id = test_level AND surface_kind = 'sprite'
                   AND name = 'STIMA0' AND pixels = '\x11' AND coverage = '\xff')
        AND NOT EXISTS (SELECT FROM doom.level_materials WHERE level_id = other_level),
        'only available actor sprites are imported per level';
    ASSERT (SELECT array_agg(ROW(type_code, thing_count)::text) FROM doom.wad_unbound_things(test_level))
        = ARRAY['(61000,2)'], 'the report counts only eligible unbound types and excludes non-actor markers';
    ASSERT NOT EXISTS (SELECT FROM doom.wad_unbound_things(test_level, 1)),
        'unknown types outside the requested skill band are excluded';
    ASSERT EXISTS (SELECT FROM doom.actor_pursuits WHERE kind = 'wad thing 3004'),
        'an imported hostile uses the existing pursuit simulation';

    test_game := doom.start_game(test_level);
    other_game := doom.start_game(test_level);
    easy_game := doom.start_game(test_level, 1);
    hard_game := doom.start_game(test_level, 5);
    ASSERT (SELECT x FROM doom.actors WHERE game_id = test_game AND kind = 'wad thing 3004') = 130
        AND (SELECT x FROM doom.actors WHERE game_id = easy_game AND kind = 'wad thing 3004') = 128
        AND (SELECT x FROM doom.actors WHERE game_id = hard_game AND kind = 'wad thing 3004') = 132,
        'skill and single-player flags select the correct hostile marker';
    ASSERT (SELECT health FROM doom.actors WHERE game_id = test_game AND kind = 'manual marker override') = 7,
        'manual bindings keep their existing flags behavior';

    SELECT * INTO STRICT player FROM doom.actors WHERE game_id = test_game AND kind = 'player';
    ASSERT player.health = 100;
    PERFORM doom._collect_wad_items(player, 56, 16);
    PERFORM doom._collect_wad_items(player, 56, 16);
    ASSERT (SELECT key_kind FROM doom.game_keys WHERE game_id = test_game) = 'blue'
        AND (SELECT amount FROM doom.game_inventory WHERE game_id = test_game AND item_kind = 'rounds') = 8
        AND NOT EXISTS (SELECT FROM doom.actors WHERE game_id = test_game AND kind IN ('wad thing 5', 'wad thing 2007')),
        'contact collects unblocked keys and supplies at full health exactly once';
    ASSERT NOT EXISTS (SELECT FROM doom.game_keys WHERE game_id = other_game)
        AND NOT EXISTS (SELECT FROM doom.game_inventory WHERE game_id = other_game)
        AND (SELECT count(*) FROM doom.actors WHERE game_id = other_game AND kind IN ('wad thing 5', 'wad thing 2007')) = 2,
        'collections are isolated per game';

    UPDATE doom.actors SET health = 70 WHERE game_id = test_game AND kind = 'player';
    PERFORM doom.tick(test_game);
    ASSERT (SELECT health FROM doom.actors WHERE game_id = test_game AND kind = 'player') = 80
        AND NOT EXISTS (SELECT FROM doom.actors WHERE game_id = test_game AND kind = 'wad thing 2011'),
        'an imported health item is processed by the normal simulation';

    BEGIN
        PERFORM doom.start_game(test_level, 0);
        RAISE EXCEPTION 'expected invalid skill to fail';
    EXCEPTION WHEN invalid_parameter_value THEN
        NULL;
    END;
END;
$$;

ROLLBACK;
