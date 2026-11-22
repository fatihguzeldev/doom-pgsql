BEGIN;
SET LOCAL plpgsql.check_asserts = on;

DO $$
DECLARE
    test_level bigint;
    test_game bigint;
    other_game bigint;
    geometry_game bigint;
    patch_id bigint;
    reserve_id bigint;
    other_patch_id bigint;
    scripted_health integer;
    before_frame bytea;
    after_frame bytea;
BEGIN
    INSERT INTO doom.levels (name) VALUES ('health pickup fixture') RETURNING level_id INTO test_level;
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height)
    VALUES (test_level, 0, 0, 128), (test_level, 1, 0, 128);
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id, back_sector_id)
    VALUES (test_level, 0, -64, -64, -64, 64, 0, NULL),
           (test_level, 1, -64, 64, 64, 64, 0, NULL),
           (test_level, 2, 64, 64, 64, -64, 0, 1),
           (test_level, 3, 64, -64, -64, -64, 0, NULL),
           (test_level, 4, 64, 64, 160, 64, 1, NULL),
           (test_level, 5, 160, 64, 160, -64, 1, NULL),
           (test_level, 6, 160, -64, 64, -64, 1, NULL);
    UPDATE doom.actor_types SET default_health = 125 WHERE kind = 'player';
    INSERT INTO doom.actor_types (kind, default_health, radius, height, color, blocks_actors, shootable)
    VALUES ('health patch fixture', 1, 8, 48, 16711680, false, false),
           ('health reserve fixture', 1, 8, 48, 65535, false, false);
    INSERT INTO doom.health_pickups (kind, amount)
    VALUES ('health patch fixture', 17), ('health reserve fixture', 2147483647);

    test_game := doom.start_game(test_level, 0, 0, 0);
    other_game := doom.start_game(test_level, 0, 0, 0);
    UPDATE doom.actors SET health = 75 WHERE game_id IN (test_game, other_game) AND kind = 'player';
    INSERT INTO doom.actors (game_id, kind, x, y)
    VALUES (test_game, 'health patch fixture', 24, 0) RETURNING actor_id INTO patch_id;
    INSERT INTO doom.actors (game_id, kind, x, y)
    VALUES (other_game, 'health patch fixture', 24, 0) RETURNING actor_id INTO other_patch_id;

    before_frame := doom.render(test_game, 32, 32);
    BEGIN
        PERFORM doom.step(test_game, 0, 32, p_forward => 1);
        RAISE EXCEPTION 'expected the frame to reject zero width';
    EXCEPTION WHEN invalid_parameter_value THEN
        NULL;
    END;
    ASSERT EXISTS (SELECT FROM doom.actors WHERE game_id = test_game AND actor_id = patch_id)
        AND EXISTS (SELECT FROM doom.actors WHERE game_id = test_game AND kind = 'player' AND x = 0 AND health = 75)
        AND (SELECT tick_number FROM doom.games WHERE game_id = test_game) = 0,
        'a failed frame rolls back movement, healing, consumption and the tick';

    after_frame := doom.step(test_game, 32, 32);
    ASSERT EXISTS (SELECT FROM doom.actors WHERE game_id = test_game AND kind = 'player'
                   AND health = 92 AND animation_start_tick = 0)
        AND NOT EXISTS (SELECT FROM doom.actors WHERE game_id = test_game AND actor_id = patch_id),
        'an idle tic consumes a touching SQL-spawned pickup and heals without restarting animation';
    ASSERT after_frame = doom.render(test_game, 32, 32) AND after_frame <> before_frame,
        'the combined frame removes the consumed pickup';
    ASSERT EXISTS (SELECT FROM doom.actors WHERE game_id = other_game AND actor_id = other_patch_id)
        AND (SELECT health FROM doom.actors WHERE game_id = other_game AND kind = 'player') = 75,
        'collection leaves the other game and its touching pickup alone';

    INSERT INTO doom.actors (game_id, kind, x, y)
    VALUES (test_game, 'health reserve fixture', 24, 0) RETURNING actor_id INTO reserve_id;
    FOREACH scripted_health IN ARRAY ARRAY[125, 9999, 0] LOOP
        UPDATE doom.actors SET health = scripted_health WHERE game_id = test_game AND kind = 'player';
        PERFORM doom.tick(test_game);
        ASSERT (SELECT health FROM doom.actors WHERE game_id = test_game AND kind = 'player') = scripted_health
            AND EXISTS (SELECT FROM doom.actors WHERE game_id = test_game AND actor_id = reserve_id),
            'a full, scripted above-cap or dead player leaves the pickup available';
    END LOOP;

    UPDATE doom.actors SET health = 30 WHERE game_id = test_game AND kind = 'player';
    UPDATE doom.actors SET health = 0 WHERE game_id = test_game AND actor_id = reserve_id;
    PERFORM doom.tick(test_game);
    ASSERT (SELECT health FROM doom.actors WHERE game_id = test_game AND kind = 'player') = 30
        AND EXISTS (SELECT FROM doom.actors WHERE game_id = test_game AND actor_id = reserve_id AND health = 0),
        'a pickup killed by SQL is neither consumed nor healing';
    UPDATE doom.actors SET health = 1 WHERE game_id = test_game AND actor_id = reserve_id;
    INSERT INTO doom.actors (game_id, kind, x, y)
    VALUES (test_game, 'health patch fixture', 16, 0) RETURNING actor_id INTO patch_id;
    PERFORM doom.tick(test_game);
    ASSERT (SELECT health FROM doom.actors WHERE game_id = test_game AND kind = 'player') = 125
        AND NOT EXISTS (SELECT FROM doom.actors WHERE game_id = test_game AND actor_id = reserve_id)
        AND EXISTS (SELECT FROM doom.actors WHERE game_id = test_game AND actor_id = patch_id),
        'the oldest touching actor wins and even the largest pickup safely caps at the player type health';

    geometry_game := doom.start_game(test_level, 0, 56, 0);
    UPDATE doom.actors SET health = 40 WHERE game_id = geometry_game AND kind = 'player';
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id, back_sector_id, blocking)
    VALUES (test_level, 7, 46, 64, 46, -64, 0, 0, true);
    INSERT INTO doom.actors (game_id, kind, x, y, z)
    VALUES (geometry_game, 'health patch fixture', 72, 0, 0),
           (geometry_game, 'health patch fixture', 56, 0, 56),
           (geometry_game, 'health patch fixture', 55, 24, 0),
           (geometry_game, 'health patch fixture', 40, 0, 0);
    PERFORM doom.tick(geometry_game);
    ASSERT (SELECT health FROM doom.actors WHERE game_id = geometry_game AND kind = 'player') = 40
        AND (SELECT count(*) FROM doom.actors WHERE game_id = geometry_game AND kind <> 'player') = 4,
        'another sector, exact vertical tangency, diagonal separation and a blocking wall prevent collection';

    UPDATE doom.lines SET blocking = false WHERE level_id = test_level AND line_id = 7;
    UPDATE doom.actors SET z = 55 WHERE game_id = geometry_game AND z = 56;
    UPDATE doom.actors SET y = 23 WHERE game_id = geometry_game AND y = 24;
    PERFORM doom.tick(geometry_game);
    ASSERT (SELECT health FROM doom.actors WHERE game_id = geometry_game AND kind = 'player') = 91
        AND (SELECT array_agg(sector_id) FROM doom.actors WHERE game_id = geometry_game AND kind <> 'player') = ARRAY[1],
        'unobstructed overlapping pickups are each collected while health remains below the cap';
END;
$$;

DO $$
DECLARE
    test_level bigint;
    batched_game bigint;
    single_game bigint;
    screened_game bigint;
    batched_player doom.actors;
    single_player doom.actors;
BEGIN
    INSERT INTO doom.levels (name) VALUES ('health pickup timing fixture') RETURNING level_id INTO test_level;
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height) VALUES (test_level, 0, 0, 128);
    UPDATE doom.actor_types SET default_health = 100 WHERE kind = 'player';
    INSERT INTO doom.actor_types (kind, default_health, radius, height, blocks_actors, shootable)
    VALUES ('healing packet fixture', 1, 8, 48, false, false);
    INSERT INTO doom.health_pickups (kind, amount) VALUES ('healing packet fixture', 25);
    INSERT INTO doom.actor_types (kind, default_health, radius, attack_range, attack_damage)
    VALUES ('pickup pursuer fixture', 30, 8, 40, 25);
    INSERT INTO doom.actor_pursuits (kind, sight_range, move_distance, interval_ticks)
    VALUES ('pickup pursuer fixture', 128, 0, 1);

    batched_game := doom.start_game(test_level, 0, 0, 0);
    single_game := doom.start_game(test_level, 0, 0, 0);
    screened_game := doom.start_game(test_level, 0, 0, 0);
    INSERT INTO doom.actors (game_id, sector_id, kind, x, y)
    SELECT game_id, 0, kind, x, 0
    FROM unnest(ARRAY[batched_game, single_game, screened_game]) AS game(game_id)
    CROSS JOIN (VALUES ('healing packet fixture', 40), ('pickup pursuer fixture', 72)) AS actor(kind, x);

    PERFORM doom.tick(screened_game, p_fire => true);
    ASSERT (SELECT health FROM doom.actors WHERE game_id = screened_game AND kind = 'pickup pursuer fixture') = 10,
        'a pickup does not screen a target from the player';
    UPDATE doom.actors SET x = 16 WHERE game_id = screened_game AND kind = 'player';
    PERFORM doom.tick(screened_game);
    ASSERT (SELECT health FROM doom.actors WHERE game_id = screened_game AND kind = 'player') = 75
        AND (SELECT health FROM doom.actors WHERE game_id = screened_game AND kind = 'healing packet fixture') = 1,
        'a full player leaves the pickup alive and the pursuer shoots through it';

    UPDATE doom.actors SET health = 12 WHERE game_id IN (batched_game, single_game) AND kind = 'player';
    PERFORM doom.tick(batched_game, p_forward => 1, p_ticks => 3);
    PERFORM doom.tick(single_game, p_forward => 1);
    PERFORM doom.tick(single_game, p_forward => 1);
    ASSERT EXISTS (SELECT FROM doom.actors WHERE game_id = single_game AND kind = 'player' AND x = 16 AND health = 12)
        AND NOT EXISTS (SELECT FROM doom.actors WHERE game_id = single_game AND kind = 'healing packet fixture'),
        'a moved player consumes the pickup before a would-be lethal pursuer hit on the same tic';
    PERFORM doom.tick(single_game, p_forward => 1);

    SELECT * INTO STRICT batched_player FROM doom.actors WHERE game_id = batched_game AND kind = 'player';
    SELECT * INTO STRICT single_player FROM doom.actors WHERE game_id = single_game AND kind = 'player';
    ASSERT batched_player.x = 24 AND batched_player.health = 0 AND batched_player.animation_start_tick = 3
        AND (batched_player.x, batched_player.health, batched_player.animation_start_tick)
          = (single_player.x, single_player.health, single_player.animation_start_tick)
        AND (SELECT tick_number FROM doom.games WHERE game_id = batched_game) = 3
        AND NOT EXISTS (SELECT FROM doom.actors WHERE game_id = batched_game AND kind = 'healing packet fixture'),
        'moving, healing and taking damage in a batch matches individual tics';
END;
$$;

ROLLBACK;
