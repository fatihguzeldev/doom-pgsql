BEGIN;
SET LOCAL plpgsql.check_asserts = on;

DO $$
DECLARE
    test_level bigint;
    test_game bigint;
    player doom.actors;
BEGIN
    INSERT INTO doom.levels (name) VALUES ('start marker fixture') RETURNING level_id INTO test_level;
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height)
    VALUES (test_level, 0, 8, 96);
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id)
    VALUES (test_level, 0, 0, 0, 0, 64, 0),
           (test_level, 1, 0, 64, 64, 64, 0),
           (test_level, 2, 64, 64, 64, 0, 0),
           (test_level, 3, 64, 0, 0, 0, 0);

    BEGIN
        PERFORM doom.start_game(test_level);
        RAISE EXCEPTION 'expected a missing player start to fail';
    EXCEPTION WHEN invalid_parameter_value THEN
        NULL;
    END;

    INSERT INTO doom.level_things (level_id, thing_id, x, y, angle_deg, type_code, flags)
    VALUES (test_level, 0, 48, 48, 0, 2, 0),
           (test_level, 1, 16, 24, 90, 1, 0);
    test_game := doom.start_game(test_level);

    SELECT * INTO STRICT player FROM doom.actors WHERE game_id = test_game AND kind = 'player';
    ASSERT (player.x, player.y, player.z, player.sector_id) = (16, 24, 8, 0),
        'player starts at the primary marker using the game floor';
    ASSERT player.angle = pi() / 2, 'imported angle is converted from degrees to radians';
END;
$$;

ROLLBACK;
