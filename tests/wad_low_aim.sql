BEGIN;
SET LOCAL plpgsql.check_asserts = on;

DO $$
DECLARE
    fixture_level bigint;
    fixture_game bigint;
    target_id bigint;
BEGIN
    INSERT INTO doom.levels (name) VALUES ('low target fixture') RETURNING level_id INTO fixture_level;
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height)
    SELECT fixture_level, sector_id, 0, 96 FROM generate_series(0, 2) AS sector(sector_id);
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id, back_sector_id)
    VALUES (fixture_level, 0, 0, -32, 0, 32, 0, NULL),
           (fixture_level, 1, 0, 32, 48, 32, 0, NULL),
           (fixture_level, 2, 48, 32, 48, -32, 0, 1),
           (fixture_level, 3, 48, -32, 0, -32, 0, NULL),
           (fixture_level, 4, 48, 32, 96, 32, 1, NULL),
           (fixture_level, 5, 96, 32, 96, -32, 1, 2),
           (fixture_level, 6, 96, -32, 48, -32, 1, NULL),
           (fixture_level, 7, 96, 32, 144, 32, 2, NULL),
           (fixture_level, 8, 144, 32, 144, -32, 2, NULL),
           (fixture_level, 9, 144, -32, 96, -32, 2, NULL);
    INSERT INTO doom.actor_types (kind, default_health, radius, height)
    VALUES ('low target specimen', 40, 8, 28);
    INSERT INTO doom.level_actor_bindings (level_id, type_code, kind, use_wad_flags)
    VALUES (fixture_level, 47001, 'low target specimen', true);
    fixture_game := doom.start_game(fixture_level, 0, 16, 0);
    INSERT INTO doom.actors (game_id, sector_id, kind, x, y)
    VALUES (fixture_game, 2, 'low target specimen', 120, 0) RETURNING actor_id INTO target_id;

    PERFORM doom.tick(fixture_game, p_fire => true);
    ASSERT (SELECT health FROM doom.actors WHERE game_id = fixture_game AND actor_id = target_id) = 20,
        'a low body in a clear imported passage is reachable without pitch input';

    INSERT INTO doom.sector_state (game_id, level_id, sector_id, floor_height, ceiling_height)
    VALUES (fixture_game, fixture_level, 1, 32, 96);
    PERFORM doom.tick(fixture_game, p_fire => true);
    ASSERT (SELECT health FROM doom.actors WHERE game_id = fixture_game AND actor_id = target_id) = 20,
        'a raised floor blocks the low path';

    UPDATE doom.sector_state SET floor_height = 0, ceiling_height = 32
    WHERE game_id = fixture_game AND sector_id = 1;
    PERFORM doom.tick(fixture_game, p_fire => true);
    ASSERT (SELECT health FROM doom.actors WHERE game_id = fixture_game AND actor_id = target_id) = 20,
        'the low path alone cannot bypass a blocker at the shooter height';

    DELETE FROM doom.sector_state WHERE game_id = fixture_game AND sector_id = 1;
    UPDATE doom.level_actor_bindings SET use_wad_flags = false WHERE level_id = fixture_level;
    PERFORM doom.tick(fixture_game, p_fire => true);
    ASSERT (SELECT health FROM doom.actors WHERE game_id = fixture_game AND actor_id = target_id) = 20,
        'authored actor bindings use the original eye-height ray';
END;
$$;

ROLLBACK;
