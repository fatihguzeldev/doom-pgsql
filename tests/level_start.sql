BEGIN;
SET LOCAL plpgsql.check_asserts = on;

DO $$
DECLARE
    test_level bigint;
    other_level bigint;
    test_game bigint;
    explicit_game bigint;
    player doom.actors;
    game_count bigint;
    actor_count bigint;
BEGIN
    INSERT INTO doom.levels (name) VALUES ('start marker fixture') RETURNING level_id INTO test_level;
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height)
    VALUES (test_level, 0, 8, 96), (test_level, 1, 24, 112);
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id, back_sector_id)
    VALUES (test_level, 0, 0, 0, 0, 64, 0, NULL),
           (test_level, 1, 0, 64, 64, 64, 0, NULL),
           (test_level, 2, 64, 64, 64, 0, 0, 1),
           (test_level, 3, 64, 0, 0, 0, 0, NULL),
           (test_level, 4, 64, 64, 128, 64, 1, NULL),
           (test_level, 5, 128, 64, 128, 0, 1, NULL),
           (test_level, 6, 128, 0, 64, 0, 1, NULL);

    BEGIN
        PERFORM doom.start_game(test_level);
        RAISE EXCEPTION 'expected a missing player start to fail';
    EXCEPTION WHEN invalid_parameter_value THEN
        NULL;
    END;

    INSERT INTO doom.levels (name) VALUES ('independent marker binding fixture') RETURNING level_id INTO other_level;
    INSERT INTO doom.actor_types (kind, default_health)
    VALUES ('marker sentinel fixture', 37), ('marker beacon fixture', 12);
    INSERT INTO doom.level_actor_bindings (level_id, type_code, kind)
    VALUES (test_level, 41001, 'marker sentinel fixture'), (test_level, 41002, 'marker beacon fixture'),
           (other_level, 41001, 'marker beacon fixture');
    INSERT INTO doom.level_things (level_id, thing_id, x, y, angle_deg, type_code, flags)
    VALUES (test_level, 6, 32, 12, 180, 41002, 0),
           (test_level, 1, 16, 24, 90, 1, 0),
           (test_level, 4, 88, 36, 270, 41001, 65535),
           (test_level, 2, 48, 48, 0, 1, 0),
           (test_level, 0, 168, 128, 0, 41009, 0);
    test_game := doom.start_game(test_level);

    SELECT * INTO STRICT player FROM doom.actors WHERE game_id = test_game AND kind = 'player';
    ASSERT (player.x, player.y, player.z, player.sector_id) = (16, 24, 8, 0),
        'player starts at the primary marker using the game floor';
    ASSERT player.angle = pi() / 2, 'imported angle is converted from degrees to radians';
    ASSERT (SELECT array_agg(kind ORDER BY actor_id) FROM doom.actors WHERE game_id = test_game)
        = ARRAY['player', 'marker sentinel fixture', 'marker beacon fixture'],
        'one launch inserts only its mapped actors in marker order';
    ASSERT EXISTS (SELECT FROM doom.actors WHERE game_id = test_game AND kind = 'marker sentinel fixture'
                   AND (x, y, z, sector_id, health, animation_start_tick) = (88, 36, 24, 1, 37, 0)
                   AND angle = radians(270)), 'mapped marker uses the resolved floor, actor defaults and angle';
    ASSERT EXISTS (SELECT FROM doom.actors WHERE game_id = test_game AND kind = 'marker beacon fixture'
                   AND (x, y, z, sector_id, health, animation_start_tick) = (32, 12, 8, 0, 12, 0)
                   AND angle = pi()), 'a second marker resolves independently';

    explicit_game := doom.start_game(test_level, 0, 20, 28);
    ASSERT (SELECT array_agg(kind) FROM doom.actors WHERE game_id = explicit_game) = ARRAY['player'],
        'an explicit start spawns only its player';

    SELECT count(*) INTO game_count FROM doom.games WHERE level_id = test_level;
    SELECT count(*) INTO actor_count FROM doom.actors WHERE level_id = test_level;
    INSERT INTO doom.level_things (level_id, thing_id, x, y, angle_deg, type_code, flags)
    VALUES (test_level, 8, 168, 128, 0, 41002, 0);
    BEGIN
        PERFORM doom.start_game(test_level);
        RAISE EXCEPTION 'expected a mapped marker outside the level to fail';
    EXCEPTION WHEN check_violation THEN
        NULL;
    END;
    ASSERT (SELECT count(*) FROM doom.games WHERE level_id = test_level) = game_count
        AND (SELECT count(*) FROM doom.actors WHERE level_id = test_level) = actor_count,
        'an invalid mapped marker rolls back the game and its spawned actors';
END;
$$;

ROLLBACK;
