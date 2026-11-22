\set ON_ERROR_STOP on
BEGIN;

DO $$
DECLARE
    map_id bigint;
    game bigint;
    game_epoch bigint;
    player_x double precision;
BEGIN
    INSERT INTO doom.levels (name) VALUES ('SIMTEST') RETURNING level_id INTO map_id;
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height)
    VALUES (map_id, 0, 0, 128);
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id)
    VALUES (map_id, 0, 0, 0, 0, 128, 0), (map_id, 1, 0, 128, 128, 128, 0),
           (map_id, 2, 128, 128, 128, 0, 0), (map_id, 3, 128, 0, 0, 0, 0);
    INSERT INTO doom.level_things (level_id, thing_id, x, y, angle_deg, type_code, flags)
    VALUES (map_id, 0, 32, 64, 0, 1, 7);
    game := doom.start(map_id);
    SELECT epoch INTO STRICT game_epoch FROM doom.games WHERE game_id = game;

    IF doom.tick(game, game_epoch, 1, 1, 0, 0, false, false) <> 1 THEN
        RAISE EXCEPTION 'first tick did not commit';
    END IF;
    IF doom.tick(game, game_epoch, 1, 1, 0, 0, false, false) <> 1 THEN
        RAISE EXCEPTION 'duplicate tick returned the wrong clock';
    END IF;
    SELECT x INTO STRICT player_x FROM doom.actors WHERE game_id = game AND kind = 'player';
    IF player_x <> 40 THEN
        RAISE EXCEPTION 'duplicate tick moved the player twice, x=%', player_x;
    END IF;
    BEGIN
        PERFORM doom.tick(game, game_epoch, 1, 0, 0, 0, false, false);
        RAISE EXCEPTION 'conflicting input for the last tic was accepted';
    EXCEPTION WHEN invalid_parameter_value THEN
        NULL;
    END;
    BEGIN
        PERFORM doom.tick(game, game_epoch, 3, 0, 0, 0, false, false);
        RAISE EXCEPTION 'a skipped tick was accepted';
    EXCEPTION WHEN SQLSTATE 'PDT01' THEN
        NULL;
    END;
    BEGIN
        PERFORM doom.tick(game, game_epoch + 1, 2, 0, 0, 0, false, false);
        RAISE EXCEPTION 'a wrong epoch was accepted';
    EXCEPTION WHEN invalid_parameter_value THEN
        NULL;
    END;

    FOR tic IN 2..25 LOOP
        PERFORM doom.tick(game, game_epoch, tic, 1, 0, 0, false, false);
    END LOOP;
    SELECT x INTO STRICT player_x FROM doom.actors WHERE game_id = game AND kind = 'player';
    IF player_x < 111.9 OR player_x > 112.000001 THEN
        RAISE EXCEPTION 'the actor radius did not stop at the wall, x=%', player_x;
    END IF;
END;
$$;
DO $$
DECLARE
    map_id bigint;
    game bigint;
    game_epoch bigint;
    ammunition integer;
    barrel bigint;
BEGIN
    INSERT INTO doom.levels (name) VALUES ('SIMDOOR') RETURNING level_id INTO map_id;
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height)
    VALUES (map_id, 0, 0, 128), (map_id, 1, 0, 0), (map_id, 2, 0, 128);
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2,
                             front_sector_id, back_sector_id, special)
    VALUES (map_id, 0, 0, 0, 0, 128, 0, NULL, 0),
           (map_id, 1, 0, 128, 128, 128, 0, NULL, 0),
           (map_id, 2, 128, 128, 128, 0, 0, 1, 27),
           (map_id, 3, 128, 0, 0, 0, 0, NULL, 0),
           (map_id, 4, 128, 128, 160, 128, 1, NULL, 0),
           (map_id, 5, 160, 128, 160, 0, 1, 2, 0),
           (map_id, 6, 160, 0, 128, 0, 1, NULL, 0),
           (map_id, 7, 160, 128, 320, 128, 2, NULL, 0),
           (map_id, 8, 320, 128, 320, 0, 2, NULL, 11),
           (map_id, 9, 320, 0, 160, 0, 2, NULL, 0);
    INSERT INTO doom.level_things (level_id, thing_id, x, y, angle_deg, type_code, flags, sector_id)
    VALUES (map_id, 0, 80, 64, 0, 1, 7, 0),
           (map_id, 1, 34, 64, 0, 6, 7, 0),
           (map_id, 2, 244, 64, 0, 2035, 7, 2);
    game := doom.start(map_id);
    SELECT epoch INTO STRICT game_epoch FROM doom.games WHERE game_id = game;
    SELECT actor_id INTO STRICT barrel FROM doom.actors WHERE game_id = game AND type_id = 2035;

    PERFORM doom.tick(game, game_epoch, 1, 0, 0, 0, true, false);
    IF EXISTS (SELECT FROM doom.sector_motions WHERE game_id = game) THEN
        RAISE EXCEPTION 'locked door opened without the key';
    END IF;
    FOR tic IN 2..4 LOOP
        PERFORM doom.tick(game, game_epoch, tic, -1, 0, 0, false, false);
    END LOOP;
    IF NOT EXISTS (SELECT FROM doom.game_inventory WHERE game_id = game AND item = 'key-yellow')
        OR EXISTS (SELECT FROM doom.actors WHERE game_id = game AND type_id = 6) THEN
        RAISE EXCEPTION 'walking over the yellow key did not collect it';
    END IF;
    PERFORM doom.tick(game, game_epoch, 5, 1, 0, 0, false, false);
    PERFORM doom.tick(game, game_epoch, 6, 0, 0, 0, true, false);
    FOR tic IN 7..75 LOOP
        PERFORM doom.tick(game, game_epoch, tic, 0, 0, 0, false, false);
    END LOOP;
    IF NOT EXISTS (SELECT FROM doom.sector_state WHERE game_id = game AND sector_id = 1
                   AND ceiling_height = 124) THEN
        RAISE EXCEPTION 'keyed door did not reach the open height';
    END IF;

    FOR tic IN 76..94 LOOP
        PERFORM doom.tick(game, game_epoch, tic, 1, 0, 0, false, false);
    END LOOP;
    IF NOT EXISTS (SELECT FROM doom.actors WHERE game_id = game AND kind = 'player'
                   AND sector_id = 2) THEN
        RAISE EXCEPTION 'player did not pass through the open door';
    END IF;

    PERFORM doom.tick(game, game_epoch, 95, 0, 0, 0, false, true);
    PERFORM doom.tick(game, game_epoch, 95, 0, 0, 0, false, true);
    SELECT amount INTO STRICT ammunition FROM doom.game_inventory WHERE game_id = game AND item = 'bullets';
    IF ammunition <> 49 OR NOT EXISTS (SELECT FROM doom.actors WHERE game_id = game AND actor_id = barrel
                                        AND health = 0 AND animation_start_tick = 95) THEN
        RAISE EXCEPTION 'repeat-safe low barrel shot did not deal damage and consume one round';
    END IF;

    FOR tic IN 96..101 LOOP
        PERFORM doom.tick(game, game_epoch, tic, 1, 0, 0, false, false);
    END LOOP;
    PERFORM doom.tick(game, game_epoch, 102, 0, 0, 0, true, false);
    IF NOT EXISTS (SELECT FROM doom.games WHERE game_id = game AND finished_at_tick = 102 AND exit_kind = 'normal')
       OR doom.tick(game, game_epoch, 103, 1, 0, 0, false, false) <> 102 THEN
        RAISE EXCEPTION 'the exit switch did not finish the map';
    END IF;
END;
$$;

DO $$
DECLARE
    map_id bigint;
    game bigint;
    game_epoch bigint;
BEGIN
    INSERT INTO doom.levels (name) VALUES ('SIMAI') RETURNING level_id INTO map_id;
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height)
    VALUES (map_id, 0, 0, 128);
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id)
    VALUES (map_id, 0, 0, 0, 0, 128, 0), (map_id, 1, 0, 128, 512, 128, 0),
           (map_id, 2, 512, 128, 512, 0, 0), (map_id, 3, 512, 0, 0, 0, 0);
    INSERT INTO doom.level_things (level_id, thing_id, x, y, angle_deg, type_code, flags, sector_id)
    VALUES (map_id, 0, 32, 64, 0, 1, 7, 0), (map_id, 1, 300, 64, 180, 3004, 7, 0);
    game := doom.start(map_id);
    SELECT epoch INTO STRICT game_epoch FROM doom.games WHERE game_id = game;
    PERFORM doom.tick(game, game_epoch, 1, 0, 0, 0, false, false);
    IF NOT EXISTS (SELECT FROM doom.actors WHERE game_id = game AND kind = 'monster' AND x = 296) THEN
        RAISE EXCEPTION 'a guard with line of sight did not pursue';
    END IF;
    UPDATE doom.actors SET x = 80 WHERE game_id = game AND kind = 'monster';
    FOR tic IN 2..9 LOOP
        PERFORM doom.tick(game, game_epoch, tic, 0, 0, 0, false, false);
    END LOOP;
    IF NOT EXISTS (SELECT FROM doom.actors WHERE game_id = game AND kind = 'player' AND health = 96) THEN
        RAISE EXCEPTION 'the guard did not attack from its updated SQL position';
    END IF;
    PERFORM doom.tick(game, game_epoch, 10, 0, 0, 0, false, true);
    IF NOT EXISTS (SELECT FROM doom.actors WHERE game_id = game AND kind = 'monster'
                   AND health = 0 AND sprite_material = 'POSSL0') THEN
        RAISE EXCEPTION 'a shot did not kill the guard or select its corpse sprite';
    END IF;
END;
$$;

ROLLBACK;
