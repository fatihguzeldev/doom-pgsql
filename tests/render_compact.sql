BEGIN;
SET LOCAL plpgsql.check_asserts = on;

DO $$
DECLARE
    test_level bigint;
    test_game bigint;
    target_actor bigint;
    solid_rgb bytea;
    solid_spans bytea;
    tied_rgb bytea;
    textured_rgb bytea;
    textured_spans bytea;
    palette bytea := '\x000000ffbf00'::bytea || decode(repeat('00', 762), 'hex');
    before_step bytea;
    after_step bytea;
BEGIN
    INSERT INTO doom.levels (name) VALUES ('compact render fixture')
    RETURNING level_id INTO test_level;
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height, light_level)
    VALUES (test_level, 0, 0, 64, 255);
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id)
    VALUES (test_level, 0, 48, 64, 48, -64, 0);
    test_game := doom.start_game(test_level, 0, 0, 0);

    solid_rgb := doom.render(test_game, 7, 8);
    solid_spans := doom.render_spans(test_game, 7, 8);
    ASSERT octet_length(solid_spans) = 147 AND octet_length(solid_rgb) = 168,
        'the ceiling, wall and floor create three span records per column';
    ASSERT doom.render_compact(test_game, 7, 8) IS NOT DISTINCT FROM '\x01'::bytea || solid_spans,
        'a sparse scene chooses the exact span packet';

    tied_rgb := doom.render(test_game, 7, 7);
    ASSERT octet_length(tied_rgb) = 147 AND octet_length(doom.render_spans(test_game, 7, 7)) = 147,
        'reducing the height by one creates a tie without changing the number of records';
    ASSERT doom.render_compact(test_game, 7, 7) IS NOT DISTINCT FROM '\x00'::bytea || tied_rgb,
        'a tie chooses the exact RGB bytes';

    INSERT INTO doom.level_palettes (level_id, palette) VALUES (test_level, palette);
    INSERT INTO doom.level_materials (level_id, surface_kind, name, width, height, pixels, coverage)
    VALUES (test_level, 'wall', 'STRIPE', 1, 2, '\x0001', '\xffff'),
           (test_level, 'flat', 'UNUSED', 1, 1, '\x01', '\xff');
    INSERT INTO doom.line_surfaces (level_id, line_id, is_back, middle_material)
    VALUES (test_level, 0, false, 'stripe');

    textured_rgb := doom.render(test_game, 7, 8);
    ASSERT octet_length(doom.render_spans(test_game, 7, 8)) > octet_length(textured_rgb)
        AND textured_rgb IS DISTINCT FROM solid_rgb,
        'resolved texture samples make span packets larger than RGB';
    ASSERT doom.render_compact(test_game, 7, 8) IS NOT DISTINCT FROM '\x00'::bytea || textured_rgb,
        'a dense textured scene chooses the exact RGB bytes';

    tied_rgb := doom.render(test_game, 6, 14);
    ASSERT octet_length(tied_rgb) = 252 AND octet_length(doom.render_spans(test_game, 6, 14)) = 252,
        'four textured rows, floor and ceiling tie the RGB size';
    ASSERT doom.render_compact(test_game, 6, 14) IS NOT DISTINCT FROM '\x00'::bytea || tied_rgb,
        'a tie from sampled texels also chooses the exact RGB bytes';

    textured_spans := doom.render_spans(test_game, 6, 15);
    ASSERT octet_length(textured_spans) = 252,
        'adding a row preserves the number of records in this textured view';
    ASSERT doom.render_compact(test_game, 6, 15) IS NOT DISTINCT FROM '\x01'::bytea || textured_spans,
        'textured spans are preserved when they use fewer bytes';

    DELETE FROM doom.level_palettes WHERE level_id = test_level;
    ASSERT doom.render_compact(test_game, 7, 8) IS NOT DISTINCT FROM '\x01'::bytea || solid_spans,
        'a missing palette restores the smaller solid span packet';

    INSERT INTO doom.level_palettes (level_id, palette) VALUES (test_level, palette);
    DELETE FROM doom.level_materials WHERE level_id = test_level AND surface_kind = 'wall' AND name = 'STRIPE';
    ASSERT doom.render_spans(test_game, 7, 8) IS NOT DISTINCT FROM solid_spans,
        'an unresolved wall again emits a single solid record per column';
    ASSERT doom.render_compact(test_game, 7, 8) IS NOT DISTINCT FROM '\x01'::bytea || solid_spans,
        'a missing wall material does not inflate the chosen encoding despite other loaded materials';

    INSERT INTO doom.actor_types (kind, default_health, radius)
    VALUES ('compact fixture blocker', 20, 8);
    INSERT INTO doom.actors (game_id, sector_id, kind, x, y)
    VALUES (test_game, 0, 'compact fixture blocker', 26, 0) RETURNING actor_id INTO target_actor;
    before_step := doom.render_compact(test_game, 7, 8);

    BEGIN
        PERFORM doom.step_compact(test_game, 0, 8, p_forward => 1, p_ticks => 2, p_fire => true);
        RAISE EXCEPTION 'expected compact step to reject zero width';
    EXCEPTION WHEN invalid_parameter_value THEN
        NULL;
    END;
    ASSERT (SELECT tick_number FROM doom.games WHERE game_id = test_game) = 0
        AND (SELECT x FROM doom.actors WHERE game_id = test_game AND kind = 'player') = 0
        AND (SELECT health FROM doom.actors WHERE game_id = test_game AND actor_id = target_actor) = 20,
        'invalid dimensions roll back the tick batch, movement and shot damage';

    after_step := doom.step_compact(test_game, 7, 8, p_forward => 1, p_ticks => 2, p_fire => true);
    ASSERT (SELECT tick_number FROM doom.games WHERE game_id = test_game) = 2
        AND (SELECT x FROM doom.actors WHERE game_id = test_game AND kind = 'player') = 16
        AND EXISTS (SELECT FROM doom.actors WHERE game_id = test_game AND actor_id = target_actor
                    AND health = 0 AND animation_start_tick = 1),
        'a combined action kills the blocker before moving and advances exactly two tics';
    ASSERT after_step IS DISTINCT FROM before_step
        AND after_step IS NOT DISTINCT FROM doom.render_compact(test_game, 7, 8),
        'the combined call returns the frame rendered from its new state';
END;
$$;

ROLLBACK;
