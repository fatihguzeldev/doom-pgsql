\set ON_ERROR_STOP on
BEGIN;
SET LOCAL plpgsql.check_asserts = on;

DO $$
DECLARE
    test_level bigint;
    test_game bigint;
    player doom.actors;
BEGIN
    INSERT INTO doom.levels (name) VALUES ('four open rooms') RETURNING level_id INTO test_level;
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height)
    SELECT test_level, sector_id, 0, 128 FROM generate_series(0, 3) AS sector_id;

    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id, back_sector_id)
    VALUES (test_level, 0, 0, 0, 0, 64, 0, NULL),
           (test_level, 1, 64, 64, 64, 0, 0, 1),
           (test_level, 2, 64, 0, 0, 0, 0, NULL),
           (test_level, 3, 0, 64, 64, 64, 0, 2),
           (test_level, 4, 64, 64, 128, 64, 1, 3),
           (test_level, 5, 128, 64, 128, 0, 1, NULL),
           (test_level, 6, 128, 0, 64, 0, 1, NULL),
           (test_level, 7, 0, 64, 0, 128, 2, NULL),
           (test_level, 8, 0, 128, 64, 128, 2, NULL),
           (test_level, 9, 64, 128, 64, 64, 2, 3),
           (test_level, 10, 64, 128, 128, 128, 3, NULL),
           (test_level, 11, 128, 128, 128, 64, 3, NULL);

    test_game := doom.start_game(test_level, 0, 60, 60);
    PERFORM doom.tick(test_game, 1, 1);
    SELECT * INTO STRICT player FROM doom.actors WHERE game_id = test_game AND kind = 'player';

    ASSERT player.x > 64 AND player.y > 64, 'diagonal move crosses the shared corner';
    ASSERT player.sector_id = 3,
        format('diagonal move must enter sector 3, recorded %s at (%s, %s)', player.sector_id, player.x, player.y);
END;
$$;

ROLLBACK;
