BEGIN;
SET LOCAL plpgsql.check_asserts = on;

DO $$
DECLARE
    level bigint;
    first_game bigint;
    second_game bigint;
    group_kind text;
    first_enemy bigint;
BEGIN
    SELECT kind INTO STRICT group_kind FROM doom.wad_actor_types WHERE type_code = 3003;
    INSERT INTO doom.levels (name) VALUES ('tagged floor encounter') RETURNING level_id INTO level;
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height)
    VALUES (level, 0, -16, 96), (level, 1, 8, 8), (level, 2, -16, 96);
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id, back_sector_id)
    VALUES (level, 0, 128, 64, 128, 0, 0, 1);
    INSERT INTO doom.wad_sector_properties (level_id, sector_id, special, tag)
    VALUES (level, 1, 0, 666), (level, 2, 11, 0);
    INSERT INTO doom.level_actor_bindings (level_id, type_code, kind) VALUES (level, 3003, group_kind);
    PERFORM doom._bind_wad_encounters(level);
    ASSERT (SELECT target_height FROM doom.encounter_floor_targets WHERE level_id = level AND sector_id = 1) = -16;

    first_game := doom.start_game(level, 0, 32, 32);
    second_game := doom.start_game(level, 0, 32, 32);
    INSERT INTO doom.actors (game_id, sector_id, kind, x, y)
    VALUES (first_game, 0, group_kind, 1000, 0) RETURNING actor_id INTO first_enemy;
    INSERT INTO doom.actors (game_id, sector_id, kind, x, y)
    VALUES (first_game, 0, group_kind, 1080, 0), (second_game, 0, group_kind, 1000, 0);

    UPDATE doom.actors SET health = 0 WHERE game_id = first_game AND actor_id = first_enemy;
    PERFORM doom.tick(first_game);
    ASSERT NOT EXISTS (SELECT FROM doom.floor_motions WHERE game_id = first_game),
        'one remaining actor prevents the tagged floor from moving';

    UPDATE doom.actors SET health = 0 WHERE game_id = first_game AND kind = group_kind;
    PERFORM doom.tick(first_game, p_ticks => 24);
    ASSERT (SELECT floor_height FROM doom.sector_state WHERE game_id = first_game AND sector_id = 1) = -16
       AND NOT EXISTS (SELECT FROM doom.sector_state WHERE game_id = second_game)
       AND EXISTS (SELECT FROM doom.cleared_encounters WHERE game_id = first_game AND actor_kind = group_kind),
        'the next tick sees committed actor health and lowers only that game floor';

    UPDATE doom.sector_state SET floor_height = 4 WHERE game_id = first_game AND sector_id = 1;
    PERFORM doom.tick(first_game);
    ASSERT (SELECT floor_height FROM doom.sector_state WHERE game_id = first_game AND sector_id = 1) = 4,
        'clearing the same encounter again does not reschedule the floor';
END;
$$;

ROLLBACK;
