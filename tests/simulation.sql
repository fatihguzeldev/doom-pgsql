BEGIN;
SET LOCAL plpgsql.check_asserts = on;

DO $$
DECLARE
    test_level bigint;
    game bigint;
    stepped_game bigint;
    player doom.actors;
    stepped_player doom.actors;
BEGIN
    INSERT INTO doom.levels (name) VALUES ('test workshop') RETURNING level_id INTO test_level;
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height)
    VALUES (test_level, 0, 0, 96), (test_level, 1, 0, 96);
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id, back_sector_id)
    VALUES (test_level, 0, 0, 0, 0, 64, 0, NULL),
           (test_level, 1, 0, 64, 64, 64, 0, NULL),
           (test_level, 2, 64, 64, 64, 0, 0, 1),
           (test_level, 3, 64, 0, 0, 0, 0, NULL),
           (test_level, 4, 64, 64, 128, 64, 1, NULL),
           (test_level, 5, 128, 64, 128, 0, 1, NULL),
           (test_level, 6, 128, 0, 64, 0, 1, NULL);

    game := doom.start_game(test_level, 0, 48, 32, 0);
    stepped_game := doom.start_game(test_level, 0, 48, 32, 0);
    INSERT INTO doom.sector_state (game_id, level_id, sector_id, floor_height, ceiling_height)
    VALUES (game, test_level, 1, 0, 0);

    ASSERT doom.tick(game, 1, 0, 0, 4) = 4, 'batch advances four tics';
    SELECT * INTO STRICT player FROM doom.actors WHERE game_id = game AND kind = 'player';
    ASSERT player.sector_id = 0 AND abs(player.x - 48) < 0.00002,
        'closed portal blocks the player at one radius away';

    UPDATE doom.sector_state SET ceiling_height = 96 WHERE game_id = game AND sector_id = 1;
    PERFORM doom.tick(game, 1, 0, 0, 4);
    SELECT * INTO STRICT player FROM doom.actors WHERE game_id = game AND kind = 'player';
    ASSERT player.sector_id = 1 AND player.x > 64, 'open portal admits movement';

    PERFORM doom.tick(game, 1, 0, 0, 12);
    PERFORM doom.tick(stepped_game, 1, 0, 0, 19);
    PERFORM doom.tick(stepped_game, 1, 0, 0);
    SELECT * INTO STRICT player FROM doom.actors WHERE game_id = game AND kind = 'player';
    SELECT * INTO STRICT stepped_player FROM doom.actors WHERE game_id = stepped_game AND kind = 'player';
    ASSERT abs(player.x - 112) < 0.00002, 'solid perimeter leaves room for the player radius';
    ASSERT player.x = stepped_player.x AND player.sector_id = stepped_player.sector_id,
        'independently stepped movement reaches the same wall';

    PERFORM doom.tick(game, -0.125, 0.125, 0.0625, 7);
    FOR tic IN 1..7 LOOP
        PERFORM doom.tick(stepped_game, -0.125, 0.125, 0.0625);
    END LOOP;
    SELECT * INTO STRICT player FROM doom.actors WHERE game_id = game AND kind = 'player';
    SELECT * INTO STRICT stepped_player FROM doom.actors WHERE game_id = stepped_game AND kind = 'player';
    ASSERT (player.x, player.y, player.z, player.angle, player.sector_id)
        = (stepped_player.x, stepped_player.y, stepped_player.z, stepped_player.angle, stepped_player.sector_id),
        'a batch and the equivalent individual tics produce the same state';

    UPDATE doom.actors SET health = 0 WHERE game_id = game AND actor_id = player.actor_id;
    PERFORM doom.tick(game, -1, 0, 1);
    SELECT * INTO STRICT player FROM doom.actors WHERE game_id = game AND kind = 'player';
    ASSERT player.x = stepped_player.x AND player.angle = stepped_player.angle,
        'SQL-killed actors cannot move or turn';

    BEGIN
        PERFORM doom.tick(game, 0, 0, 0, 0);
        RAISE EXCEPTION 'expected a zero-size batch to fail';
    EXCEPTION WHEN invalid_parameter_value THEN
        NULL;
    END;
END;
$$;

ROLLBACK;
