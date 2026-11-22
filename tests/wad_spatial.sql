DO $$
DECLARE
    level bigint;
    segs bytea := decode('0000 0100 0000 0000 0000 0000 0100 0200 0000 0100 0100 0800', 'hex');
    leaves bytea := decode('0100 0000 0100 0100', 'hex');
    nodes bytea := decode('8000 0000 0000 0100 c000 c0ff 8000 8000 0000 c0ff c0ff 8000 0080 0180', 'hex');
    blockmap bytea := decode('c0ff c0ff 0200 0100 0600 0900 0000 0000 ffff 0000 0100 ffff', 'hex');
    seg record;
BEGIN
    INSERT INTO doom.levels (name) VALUES ('spatial fixture') RETURNING level_id INTO level;
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height)
    VALUES (level, 10, 0, 128), (level, 20, 0, 128);
    INSERT INTO doom.wad_vertices (level_id, vertex_id, x, y)
    VALUES (level, 0, -64, -64), (level, 1, 128, -64), (level, 2, 128, 192);
    INSERT INTO doom.wad_sidedefs (level_id, side_id, sector_id)
    VALUES (level, 7, 10), (level, 8, 20);
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id, back_sector_id,
                            front_side_id, back_side_id, flags)
    VALUES (level, 0, -64, -64, 128, -64, 10, NULL, 7, NULL, 0),
           (level, 1, 128, 192, 128, -64, 10, 20, 7, 8, 4);

    BEGIN
        PERFORM doom._import_wad_bsp(level, segs, leaves, overlay(nodes PLACING '\x0080'::bytea FROM 27));
        RAISE EXCEPTION 'WAD importer accepted duplicate BSP children';
    EXCEPTION WHEN invalid_parameter_value THEN
        NULL;
    END;
    IF EXISTS (SELECT FROM doom.wad_segs WHERE level_id = level) THEN
        RAISE EXCEPTION 'an invalid BSP left partial segs';
    END IF;

    PERFORM doom._import_wad_bsp(level, segs, leaves, nodes);
    SELECT * INTO STRICT seg FROM doom.wad_segs WHERE level_id = level AND seg_id = 1;
    IF ARRAY[seg.x1, seg.y1, seg.x2, seg.y2, seg.side_id, seg.front_sector_id, seg.back_sector_id, seg."offset"]
        IS DISTINCT FROM ARRAY[128, -64, 128, 192, 8, 20, 10, 8]
    THEN
        RAISE EXCEPTION 'WAD seg did not preserve its own orientation and relative texture offset: %', seg;
    END IF;
    IF doom.sector_at(level, 129, 0) IS DISTINCT FROM 10
        OR doom.sector_at(level, 127, 0) IS DISTINCT FROM 20
        OR doom.sector_at(level, 128, 0) IS DISTINCT FROM 20
    THEN
        RAISE EXCEPTION 'sector lookup did not follow the wide/left child of the partition';
    END IF;

    BEGIN
        PERFORM doom._import_wad_blockmap(level, substring(blockmap FOR 23), 2);
        RAISE EXCEPTION 'WAD importer accepted an odd BLOCKMAP length';
    EXCEPTION WHEN invalid_parameter_value THEN
        NULL;
    END;
    PERFORM doom._import_wad_blockmap(level, blockmap, 2);

    IF ARRAY(SELECT * FROM doom._wad_line_candidates(level, -32, -20, -30, -18) ORDER BY 1)
            IS DISTINCT FROM ARRAY[0]
        OR ARRAY(SELECT * FROM doom._wad_line_candidates(level, 63, -20, 65, -18) ORDER BY 1)
            IS DISTINCT FROM ARRAY[0, 1]
        OR ARRAY(SELECT * FROM doom._wad_line_candidates(level, 127, 90, 129, 100) ORDER BY 1)
            IS DISTINCT FROM ARRAY[1]
    THEN
        RAISE EXCEPTION 'inclusive BLOCKMAP and geometry fallback omitted candidates';
    END IF;

    DELETE FROM doom.levels WHERE level_id = level;
END;
$$;
