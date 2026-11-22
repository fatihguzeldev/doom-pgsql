BEGIN;
SET LOCAL plpgsql.check_asserts = on;

DO $$
DECLARE
    test_level bigint;
    test_game bigint;
    dimensions record;
    piece record;
    invalid record;
    full_frame bytea;
    observed bytea;
    assembled bytea;
    column_bytes integer;
BEGIN
    INSERT INTO doom.levels (name) VALUES ('column window fixture') RETURNING level_id INTO test_level;
    INSERT INTO doom.level_palettes (level_id, palette)
    VALUES (test_level, '\x102030ee8844aa2277448866'::bytea || decode(repeat('00', 756), 'hex'));
    INSERT INTO doom.level_materials
        (level_id, surface_kind, name, width, height, left_offset, top_offset, pixels, coverage)
    VALUES (test_level, 'flat', 'WINDOWFLAT', 2, 2, 0, 0, '\x02030302', '\xffffffff'),
           (test_level, 'wall', 'WINDOWWALL', 1, 1, 0, 0, '\x00', '\xff'),
           (test_level, 'sprite', 'WINDOWSPRITE', 5, 3, 2, 2,
               decode(repeat('01', 15), 'hex'), set_byte(decode(repeat('ff', 15), 'hex'), 7, 0));
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height, light_level,
                              floor_material, ceiling_material)
    VALUES (test_level, 0, 0, 80, 255, 'WINDOWFLAT', 'WINDOWFLAT');
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id)
    VALUES (test_level, 0, 80, 128, 80, -128, 0);
    INSERT INTO doom.line_surfaces (level_id, line_id, is_back, middle_material)
    VALUES (test_level, 0, false, 'WINDOWWALL');
    INSERT INTO doom.actor_types (kind, default_health, radius, height, sprite_material)
    VALUES ('column-window-actor', 5, 0, 3, 'WINDOWSPRITE');
    test_game := doom.start_game(test_level, 0, 0, 0);
    INSERT INTO doom.actors (game_id, sector_id, kind, x, y, z)
    VALUES (test_game, 0, 'column-window-actor', 6.5, 0, 40);

    -- At width 13 and depth 6.5, the sprite crosses both partition cuts at columns 6 and 8.
    full_frame := doom.render_columns(test_game, 13, 15);
    ASSERT NOT EXISTS (
        SELECT FROM generate_series(5, 8) AS sprite(x)
        WHERE substring(full_frame FROM (sprite.x * 15 + 6) * 3 + 1 FOR 3)
            IS DISTINCT FROM '\xee8844'::bytea
    ), 'the sprite projects across both partition cuts';
    ASSERT substring(full_frame FROM (6 * 15 + 7) * 3 + 1 FOR 3) = '\x102030'::bytea,
        'the crop fixture exposes the textured wall behind a transparent sprite texel';

    FOR dimensions IN SELECT * FROM (VALUES (13, 15), (8, 11), (9, 14)) AS size(width, height)
    LOOP
        column_bytes := dimensions.height * 3;
        full_frame := doom.render_columns(test_game, dimensions.width, dimensions.height);
        assembled := ''::bytea;
        FOR piece IN
            SELECT * FROM (VALUES (0, dimensions.width / 2), (dimensions.width / 2, 2),
                (dimensions.width / 2 + 2, dimensions.width - dimensions.width / 2 - 2)
            ) AS part(first_column, column_count)
        LOOP
            observed := doom.render_column_window(test_game, dimensions.width, dimensions.height,
                                                  piece.first_column, piece.column_count);
            ASSERT observed IS NOT DISTINCT FROM substring(full_frame FROM piece.first_column * column_bytes + 1
                                                           FOR piece.column_count * column_bytes),
                'each window matches its full-frame column bytes';
            assembled := assembled || observed;
        END LOOP;
        ASSERT assembled IS NOT DISTINCT FROM full_frame, 'the three windows reassemble the full frame';
        ASSERT doom.render_column_window(test_game, dimensions.width, dimensions.height,
                                         dimensions.width - 1, 1)
            IS NOT DISTINCT FROM substring(full_frame FROM (dimensions.width - 1) * column_bytes + 1
                                           FOR column_bytes), 'a singleton window can end at the last column';
    END LOOP;

    ASSERT doom.render_column_window(test_game, 1, 1, 0, 1)
        IS NOT DISTINCT FROM doom.render_columns(test_game, 1, 1), 'a one-pixel frame is a valid window';

    FOR invalid IN SELECT * FROM (VALUES
        (13, 15, NULL, 1), (13, 15, 0, NULL), (13, 15, -1, 1), (13, 15, 0, 0),
        (13, 15, 0, -1), (13, 15, 12, 2), (13, 15, 13, 1),
        (13, 15, 2147483647, 1), (13, 15, 1, 2147483647),
        (NULL, 15, 0, 1), (13, NULL, 0, 1), (0, 15, 0, 1), (13, 0, 0, 1),
        (4097, 1, 0, 1), (1, 4097, 0, 1), (1025, 1024, 0, 1)
    ) AS input(width, height, first_column, column_count)
    LOOP
        BEGIN
            PERFORM doom.render_column_window(test_game, invalid.width, invalid.height,
                                              invalid.first_column, invalid.column_count);
            RAISE EXCEPTION 'expected invalid_parameter_value with width %, height %, start %, count %',
                invalid.width, invalid.height, invalid.first_column, invalid.column_count;
        EXCEPTION WHEN invalid_parameter_value THEN
            NULL;
        END;
    END LOOP;
END;
$$;

ROLLBACK;
