BEGIN;
SET LOCAL plpgsql.check_asserts = on;

CREATE FUNCTION pg_temp.assert_render_columns(p_game bigint, p_width integer, p_height integer)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    columns bytea := doom.render_columns(p_game, p_width, p_height);
    rows bytea;
BEGIN
    ASSERT octet_length(columns) = p_width * p_height * 3, 'column packet contains three bytes per pixel';
    SELECT string_agg(substring(columns FROM (x * p_height + y) * 3 + 1 FOR 3), ''::bytea ORDER BY y, x)
    INTO rows
    FROM generate_series(0, p_width - 1) AS x
    CROSS JOIN generate_series(0, p_height - 1) AS y;
    ASSERT rows IS NOT DISTINCT FROM doom.render(p_game, p_width, p_height),
        'transposing column-major pixels matches the row-major framebuffer';
END;
$$;

DO $$
DECLARE
    test_level bigint;
    test_game bigint;
    solid_frame bytea;
    masked_frame bytea;
BEGIN
    INSERT INTO doom.levels (name) VALUES ('column packets') RETURNING level_id INTO test_level;
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height, light_level, floor_color)
    VALUES (test_level, 0, 0, 80, 255, x'183048'::integer),
           (test_level, 1, 0, 80, 192, x'305070'::integer);
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id, back_sector_id, wall_color)
    VALUES (test_level, 0, 8, 64, 8, -64, 0, 1, x'777777'::integer),
           (test_level, 1, 24, 64, 24, -64, 1, NULL, x'8899aa'::integer);
    test_game := doom.start_game(test_level, 0, 0, -0.25);
    solid_frame := doom.render(test_game, 9, 41);
    PERFORM pg_temp.assert_render_columns(test_game, 9, 41);
    PERFORM pg_temp.assert_render_columns(test_game, 1, 1);

    INSERT INTO doom.level_palettes (level_id, palette)
    VALUES (test_level, '\xd04020eeaa30aa55ee'::bytea || decode(repeat('00', 759), 'hex'));
    INSERT INTO doom.level_materials (level_id, surface_kind, name, width, height, pixels, coverage)
    VALUES (test_level, 'wall', 'MASK', 3, 4, '\x000101000101010102020202', '\xff00ff00ffffffffffffffff'),
           (test_level, 'flat', 'CHECKER', 2, 2, '\x00010201', '\xffffffff');
    INSERT INTO doom.line_surfaces (level_id, line_id, is_back, x_offset, y_offset, middle_material)
    VALUES (test_level, 0, false, -67, -37, 'mask');

    masked_frame := doom.render(test_game, 9, 41);
    ASSERT masked_frame IS DISTINCT FROM solid_frame, 'the fixture projects opaque mask texels';
    PERFORM pg_temp.assert_render_columns(test_game, 9, 41);

    UPDATE doom.sectors SET floor_material = 'CHECKER' WHERE level_id = test_level AND sector_id = 0;
    PERFORM pg_temp.assert_render_columns(test_game, 13, 9);
    PERFORM pg_temp.assert_render_columns(test_game, 11, 12);

    UPDATE doom.line_surfaces SET middle_material = 'MISSING' WHERE level_id = test_level;
    PERFORM pg_temp.assert_render_columns(test_game, 9, 41);
END;
$$;

ROLLBACK;
