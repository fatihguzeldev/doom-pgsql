BEGIN;
SET LOCAL plpgsql.check_asserts = on;

DO $$
DECLARE
    test_level bigint;
    test_game bigint;
    before_frame bytea;
    after_frame bytea;
BEGIN
    INSERT INTO doom.levels (name) VALUES ('test booth') RETURNING level_id INTO test_level;
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height)
    VALUES (test_level, 0, 0, 64);
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id)
    VALUES (test_level, 0, 24, 48, 24, -48, 0);

    test_game := doom.start_game(test_level, 0, 0, 0);
    before_frame := doom.render(test_game, 16, 64);
    after_frame := doom.step(test_game, 16, 64, 1, 0, 0, 2);
    ASSERT after_frame IS DISTINCT FROM before_frame, 'the composed call renders after the move';
    ASSERT after_frame = doom.render(test_game, 16, 64), 'same frame as a separate render call';

    BEGIN
        PERFORM doom.step(test_game, 0, 64, 1);
        RAISE EXCEPTION 'expected the composed call to reject zero width';
    EXCEPTION WHEN invalid_parameter_value THEN
        NULL;
    END;

    ASSERT (SELECT tick_number FROM doom.games WHERE game_id = test_game) = 2,
        'invalid render rolls back its tick batch';
    ASSERT (SELECT x FROM doom.actors WHERE game_id = test_game AND kind = 'player') = 16,
        'invalid render rolls back movement';
END;
$$;

ROLLBACK;
