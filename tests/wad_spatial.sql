BEGIN;

DO $$
DECLARE
    level bigint;
    vertices_x integer[] := ARRAY[-64, 128, 128];
    vertices_y integer[] := ARRAY[-64, -64, 192];
    segs bytea := decode('0000 0100 0000 0000 0000 0000 0100 0200 0000 0100 0000 0000', 'hex');
    leaves bytea := decode('0100 0000 0100 0100', 'hex');
    nodes bytea := decode('8000 0000 0000 0100 0000 0000 0000 0000 0000 0000 0000 0000 0080 0180', 'hex');
    root doom._wad_bsp_node;
BEGIN
    INSERT INTO doom.levels (name) VALUES ('spatial compilation') RETURNING level_id INTO level;
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height)
    VALUES (level, 0, 0, 128), (level, 1, 0, 128);
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id)
    VALUES (level, 0, -64, -64, 128, -64, 0), (level, 1, 128, -64, 128, 192, 1);

    PERFORM doom._compile_wad_spatial(level, vertices_x, vertices_y, segs, leaves,
        overlay(nodes PLACING '\x0080'::bytea FROM 27));
    IF EXISTS (SELECT FROM doom.wad_bsp WHERE level_id = level) THEN
        RAISE EXCEPTION 'duplicated BSP children should leave the reference path available';
    END IF;

    PERFORM doom._compile_wad_spatial(level, vertices_x, vertices_y, segs, leaves, nodes);
    SELECT (bsp.nodes[1]).* INTO STRICT root FROM doom.wad_bsp AS bsp WHERE bsp.level_id = level;
    IF ARRAY[root.right_child, root.left_child, root.right_left, root.right_right, root.left_bottom, root.left_top]
        IS DISTINCT FROM ARRAY[-1, -2, -64, 128, -64, 192]
    THEN
        RAISE EXCEPTION 'compiled BSP bounds must enclose source lines, got %', root;
    END IF;

    IF doom._wad_line_candidates(level, -1, -64, 128, 0) IS DISTINCT FROM ARRAY[0, 1]
        OR doom._wad_line_candidates(level, 128, 0, 128, 0) IS DISTINCT FROM ARRAY[1]
        OR doom._wad_line_candidates(level, 1024, 1024, 1024, 1024) IS DISTINCT FROM '{}'::integer[]
    THEN
        RAISE EXCEPTION 'inclusive bounds and negative cells must preserve line candidates';
    END IF;

    UPDATE doom.lines SET wall_color = 0 WHERE level_id = level AND line_id = 0;
    IF doom._wad_line_candidates(level, 128, 0, 128, 0) IS DISTINCT FROM ARRAY[1] THEN
        RAISE EXCEPTION 'color changes should preserve compiled geometry';
    END IF;

    UPDATE doom.lines SET x2 = 129 WHERE level_id = level AND line_id = 0;
    IF doom._wad_line_candidates(level, 128, 0, 128, 0) IS NOT NULL
        OR EXISTS (SELECT FROM doom.wad_line_blocks WHERE level_id = level)
    THEN
        RAISE EXCEPTION 'a geometry edit must atomically invalidate BSP and collision candidates';
    END IF;
END;
$$;

ROLLBACK;
