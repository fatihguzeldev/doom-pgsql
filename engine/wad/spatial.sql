CREATE FUNCTION doom._import_wad_bsp(p_level_id bigint, p_segs bytea, p_subsectors bytea, p_nodes bytea)
RETURNS void
LANGUAGE plpgsql STRICT
AS $$
DECLARE
    seg_count integer := octet_length(p_segs) / 12;
    subsector_count integer := octet_length(p_subsectors) / 4;
    node_count integer := octet_length(p_nodes) / 28;
    inserted integer;
    bounds integer[];
    parent_node record;
    right_at integer;
    left_at integer;
    node_at integer;
BEGIN
    IF octet_length(p_segs) % 12 <> 0 OR octet_length(p_subsectors) % 4 <> 0
        OR octet_length(p_nodes) % 28 <> 0 OR seg_count NOT BETWEEN 1 AND 65536
        OR subsector_count NOT BETWEEN 1 AND 32768 OR node_count <> subsector_count - 1
    THEN
        RAISE EXCEPTION 'invalid WAD BSP lump sizes' USING ERRCODE = '22023';
    END IF;

    WITH decoded AS MATERIALIZED (
        SELECT id, doom.wad_u16(p_segs, id * 12) AS start_vertex,
               doom.wad_u16(p_segs, id * 12 + 2) AS end_vertex,
               doom.wad_u16(p_segs, id * 12 + 4) AS angle,
               doom.wad_u16(p_segs, id * 12 + 6) AS line_id,
               doom.wad_u16(p_segs, id * 12 + 8) AS side,
               doom.wad_i16(p_segs, id * 12 + 10) AS texture_offset
        FROM generate_series(0, seg_count - 1) AS seg(id)
    )
    INSERT INTO doom.wad_segs (
        level_id, seg_id, first_vertex_id, second_vertex_id, x1, y1, x2, y2, line_id, side,
        side_id, front_sector_id, back_sector_id, angle, "offset"
    )
    SELECT p_level_id, seg.id, seg.start_vertex, seg.end_vertex, start.x, start.y, finish.x, finish.y,
           seg.line_id, seg.side,
           CASE seg.side WHEN 0 THEN line.front_side_id ELSE line.back_side_id END,
           CASE seg.side WHEN 0 THEN line.front_sector_id ELSE line.back_sector_id END,
           CASE WHEN (line.flags & 4) = 0 THEN NULL
                WHEN seg.side = 0 THEN line.back_sector_id ELSE line.front_sector_id END,
           seg.angle, seg.texture_offset
    FROM decoded AS seg
    JOIN doom.lines AS line ON line.level_id = p_level_id AND line.line_id = seg.line_id
    JOIN doom.wad_vertices AS start ON start.level_id = p_level_id AND start.vertex_id = seg.start_vertex
    JOIN doom.wad_vertices AS finish ON finish.level_id = p_level_id AND finish.vertex_id = seg.end_vertex
    WHERE (seg.side = 0 OR (seg.side = 1 AND line.back_side_id IS NOT NULL))
      AND (start.x, start.y) <> (finish.x, finish.y);

    GET DIAGNOSTICS inserted = ROW_COUNT;
    IF inserted <> seg_count THEN
        RAISE EXCEPTION 'invalid WAD segment geometry or references' USING ERRCODE = '22023';
    END IF;

    WITH decoded AS MATERIALIZED (
        SELECT id, doom.wad_u16(p_subsectors, id * 4) AS size,
               doom.wad_u16(p_subsectors, id * 4 + 2) AS first_seg_id
        FROM generate_series(0, subsector_count - 1) AS subsector(id)
    ), offsets AS (
        SELECT *, coalesce(sum(size) OVER (ORDER BY id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS expected
        FROM decoded
    )
    INSERT INTO doom.wad_subsectors (level_id, subsector_id, first_seg_id, seg_count, sector_id)
    SELECT p_level_id, subsector.id, subsector.first_seg_id, subsector.size, first_seg.front_sector_id
    FROM offsets AS subsector
    JOIN doom.wad_segs AS first_seg ON first_seg.level_id = p_level_id AND first_seg.seg_id = subsector.first_seg_id
    WHERE subsector.size > 0 AND subsector.first_seg_id = subsector.expected
      AND subsector.first_seg_id + subsector.size <= seg_count
      AND (subsector.id <> subsector_count - 1 OR subsector.first_seg_id + subsector.size = seg_count);

    GET DIAGNOSTICS inserted = ROW_COUNT;
    IF inserted <> subsector_count THEN
        RAISE EXCEPTION 'invalid WAD subsector segment ranges' USING ERRCODE = '22023';
    END IF;

    WITH decoded AS (
        SELECT id, base, doom.wad_i16(p_nodes, base + 4) AS dx, doom.wad_i16(p_nodes, base + 6) AS dy,
               doom.wad_u16(p_nodes, base + 24) AS right_raw, doom.wad_u16(p_nodes, base + 26) AS left_raw
        FROM generate_series(0, node_count - 1) AS node(id)
        CROSS JOIN LATERAL (SELECT id * 28 AS base) AS record
    ), children AS (
        SELECT *, CASE WHEN right_raw >= 32768 THEN ~(right_raw - 32768) ELSE right_raw END AS right_child,
                  CASE WHEN left_raw >= 32768 THEN ~(left_raw - 32768) ELSE left_raw END AS left_child
        FROM decoded
    )
    INSERT INTO doom.wad_bsp_nodes (
        level_id, node_id, x, y, dx, dy, right_child, left_child,
        right_top, right_bottom, right_left, right_right, left_top, left_bottom, left_left, left_right
    )
    SELECT p_level_id, id, doom.wad_i16(p_nodes, base), doom.wad_i16(p_nodes, base + 2),
           dx, dy, right_child, left_child,
           doom.wad_i16(p_nodes, base + 8), doom.wad_i16(p_nodes, base + 10),
           doom.wad_i16(p_nodes, base + 12), doom.wad_i16(p_nodes, base + 14),
           doom.wad_i16(p_nodes, base + 16), doom.wad_i16(p_nodes, base + 18),
           doom.wad_i16(p_nodes, base + 20), doom.wad_i16(p_nodes, base + 22)
    FROM children
    WHERE (dx, dy) <> (0, 0)
      AND right_child BETWEEN -subsector_count AND id - 1
      AND left_child BETWEEN -subsector_count AND id - 1;

    GET DIAGNOSTICS inserted = ROW_COUNT;
    IF inserted <> node_count OR EXISTS (
        SELECT child.id
        FROM doom.wad_bsp_nodes AS node
        CROSS JOIN LATERAL (VALUES (node.right_child), (node.left_child)) AS child(id)
        WHERE node.level_id = p_level_id
        GROUP BY child.id HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION 'invalid WAD BSP tree' USING ERRCODE = '22023';
    END IF;

    -- Node IDs are topologically ordered. Derive bounds from actual segs so an
    -- undersized NODES box cannot hide geometry during visibility traversal.
    IF node_count > 0 THEN
        SELECT array_agg(field.value ORDER BY leaf.subsector_id, field.ordinal)
            || array_fill(0, ARRAY[4 * node_count])
        INTO bounds
        FROM (
            SELECT sub.subsector_id, min(least(seg.x1, seg.x2)) AS x_min,
                max(greatest(seg.x1, seg.x2)) AS x_max, min(least(seg.y1, seg.y2)) AS y_min,
                max(greatest(seg.y1, seg.y2)) AS y_max
            FROM doom.wad_subsectors AS sub
            JOIN doom.wad_segs AS seg ON seg.level_id = sub.level_id
                AND seg.seg_id >= sub.first_seg_id AND seg.seg_id < sub.first_seg_id + sub.seg_count
            WHERE sub.level_id = p_level_id
            GROUP BY sub.subsector_id
        ) AS leaf
        CROSS JOIN LATERAL unnest(ARRAY[leaf.x_min, leaf.x_max, leaf.y_min, leaf.y_max])
            WITH ORDINALITY AS field(value, ordinal);

        FOR parent_node IN SELECT node_id, right_child, left_child FROM doom.wad_bsp_nodes
            WHERE level_id = p_level_id ORDER BY node_id
        LOOP
            right_at := 4 * CASE WHEN parent_node.right_child < 0 THEN ~parent_node.right_child
                ELSE subsector_count + parent_node.right_child END + 1;
            left_at := 4 * CASE WHEN parent_node.left_child < 0 THEN ~parent_node.left_child
                ELSE subsector_count + parent_node.left_child END + 1;
            node_at := 4 * (subsector_count + parent_node.node_id) + 1;
            UPDATE doom.wad_bsp_nodes SET right_left = bounds[right_at], right_right = bounds[right_at + 1],
                right_bottom = bounds[right_at + 2], right_top = bounds[right_at + 3],
                left_left = bounds[left_at], left_right = bounds[left_at + 1],
                left_bottom = bounds[left_at + 2], left_top = bounds[left_at + 3]
            WHERE level_id = p_level_id AND node_id = parent_node.node_id;
            bounds[node_at] := least(bounds[right_at], bounds[left_at]);
            bounds[node_at + 1] := greatest(bounds[right_at + 1], bounds[left_at + 1]);
            bounds[node_at + 2] := least(bounds[right_at + 2], bounds[left_at + 2]);
            bounds[node_at + 3] := greatest(bounds[right_at + 3], bounds[left_at + 3]);
        END LOOP;
    END IF;

    INSERT INTO doom.wad_sector_lookup (level_id, nodes, leaf_sectors)
    SELECT p_level_id, coalesce((
        SELECT array_agg(member.value ORDER BY node.node_id, member.position)
        FROM doom.wad_bsp_nodes AS node
        CROSS JOIN LATERAL unnest(ARRAY[node.x, node.y, node.dx, node.dy, node.right_child, node.left_child])
            WITH ORDINALITY AS member(value, position)
        WHERE node.level_id = p_level_id
    ), '{}'), (
        SELECT array_agg(leaf.sector_id ORDER BY leaf.subsector_id)
        FROM doom.wad_subsectors AS leaf WHERE leaf.level_id = p_level_id
    );
END;
$$;

CREATE FUNCTION doom._import_wad_blockmap(p_level_id bigint, p_blockmap bytea, p_line_count integer)
RETURNS void
LANGUAGE plpgsql STRICT
AS $$
DECLARE
    word_count integer := octet_length(p_blockmap) / 2;
    width integer;
    height integer;
    cell_index integer;
    word_index integer;
    line_id integer;
    line_ids integer[];
    decoded_cells jsonb := '{}';
BEGIN
    -- Some classic editors leave this lump empty; use the line bounds index in that case.
    IF word_count = 0 AND octet_length(p_blockmap) = 0 THEN
        RETURN;
    END IF;
    IF octet_length(p_blockmap) % 2 <> 0 OR word_count < 5 THEN
        RAISE EXCEPTION 'truncated WAD BLOCKMAP' USING ERRCODE = '22023';
    END IF;
    width := doom.wad_u16(p_blockmap, 4);
    height := doom.wad_u16(p_blockmap, 6);
    IF width = 0 OR height = 0 OR width::bigint * height > least(word_count - 4, 65531) THEN
        RAISE EXCEPTION 'invalid WAD BLOCKMAP dimensions' USING ERRCODE = '22023';
    END IF;

    INSERT INTO doom.wad_blockmaps (level_id, origin_x, origin_y, width, height)
    VALUES (p_level_id, doom.wad_i16(p_blockmap, 0), doom.wad_i16(p_blockmap, 2), width, height);

    FOR cell_index IN 0 .. width * height - 1 LOOP
        word_index := doom.wad_u16(p_blockmap, 8 + cell_index * 2);
        IF word_index < 4 + width * height OR word_index >= word_count - 1
            OR doom.wad_u16(p_blockmap, word_index * 2) <> 0
        THEN
            RAISE EXCEPTION 'invalid WAD BLOCKMAP cell reference' USING ERRCODE = '22023';
        END IF;
        -- Shared list offsets are common. Decode each list just once.
        IF decoded_cells ? word_index::text THEN
            SELECT array_agg(value::integer) INTO line_ids
            FROM jsonb_array_elements_text(decoded_cells -> word_index::text);
        ELSE
            DECLARE
                list_offset integer := word_index;
            BEGIN
                line_ids := '{}';
                LOOP
                    word_index := word_index + 1;
                    IF word_index >= word_count THEN
                        RAISE EXCEPTION 'unterminated WAD BLOCKMAP cell' USING ERRCODE = '22023';
                    END IF;
                    line_id := doom.wad_u16(p_blockmap, word_index * 2);
                    EXIT WHEN line_id = 65535;
                    IF line_id >= p_line_count THEN
                        RAISE EXCEPTION 'invalid WAD BLOCKMAP line reference' USING ERRCODE = '22023';
                    END IF;
                    line_ids := array_append(line_ids, line_id);
                END LOOP;
                decoded_cells := decoded_cells || jsonb_build_object(list_offset, to_jsonb(line_ids));
            END;
        END IF;
        IF cardinality(line_ids) > 0 THEN
            INSERT INTO doom.wad_line_blocks (level_id, block_x, block_y, line_ids)
            VALUES (p_level_id, cell_index % width, cell_index / width, line_ids);
        END IF;
    END LOOP;
END;
$$;

CREATE FUNCTION doom._wad_line_candidates(
    p_level_id bigint, p_xmin double precision, p_ymin double precision,
    p_xmax double precision, p_ymax double precision
)
RETURNS SETOF integer
LANGUAGE plpgsql STABLE STRICT PARALLEL SAFE
AS $$
DECLARE
    grid doom.wad_blockmaps%ROWTYPE;
BEGIN
    SELECT * INTO grid FROM doom.wad_blockmaps WHERE level_id = p_level_id;
    IF FOUND AND p_xmin > grid.origin_x AND p_ymin > grid.origin_y
       AND p_xmax < grid.origin_x + grid.width * 128
       AND p_ymax < grid.origin_y + grid.height * 128
    THEN
        RETURN QUERY SELECT DISTINCT candidate.id
        FROM doom.wad_line_blocks AS block
        CROSS JOIN LATERAL unnest(block.line_ids) AS candidate(id)
        WHERE block.level_id = p_level_id
          AND block.block_x BETWEEN ceil((p_xmin - grid.origin_x) / 128)::integer - 1
                                AND floor((p_xmax - grid.origin_x) / 128)::integer
          AND block.block_y BETWEEN ceil((p_ymin - grid.origin_y) / 128)::integer - 1
                                AND floor((p_ymax - grid.origin_y) / 128)::integer;
    ELSE
        RETURN QUERY SELECT line.line_id
        FROM doom.lines AS line
        WHERE line.level_id = p_level_id
          AND box(point(line.x1, line.y1), point(line.x2, line.y2)) &&
              box(point(p_xmin, p_ymin), point(p_xmax, p_ymax));
    END IF;
END;
$$;

CREATE FUNCTION doom.sector_at(p_level_id bigint, p_x double precision, p_y double precision)
RETURNS integer
LANGUAGE plpgsql STABLE STRICT PARALLEL SAFE
AS $$
DECLARE
    nodes integer[];
    leaves integer[];
    child integer;
    slot integer;
    left_side boolean;
BEGIN
    SELECT lookup.nodes, lookup.leaf_sectors INTO nodes, leaves
    FROM doom.wad_sector_lookup AS lookup WHERE lookup.level_id = p_level_id;
    IF FOUND THEN
        child := cardinality(nodes) / 6 - 1;
        WHILE child >= 0 LOOP
            slot := 6 * child;
            left_side := CASE
                WHEN nodes[slot + 3] = 0 THEN (p_x <= nodes[slot + 1]) = (nodes[slot + 4] > 0)
                WHEN nodes[slot + 4] = 0 THEN (p_y <= nodes[slot + 2]) = (nodes[slot + 3] < 0)
                ELSE (p_y - nodes[slot + 2]) * nodes[slot + 3] >= (p_x - nodes[slot + 1]) * nodes[slot + 4]
            END;
            child := CASE WHEN left_side THEN nodes[slot + 6] ELSE nodes[slot + 5] END;
        END LOOP;
        RETURN leaves[-child];
    END IF;

    -- Procedural maps have no imported BSP.
    RETURN (
        SELECT side.sector_id
        FROM doom.lines AS line
        CROSS JOIN LATERAL (VALUES (line.front_sector_id), (line.back_sector_id)) AS side(sector_id)
        WHERE line.level_id = p_level_id AND side.sector_id IS NOT NULL
          AND CASE WHEN (line.y1 > p_y) <> (line.y2 > p_y)
              THEN p_x < line.x1 + (p_y - line.y1) * (line.x2::double precision - line.x1)
                      / (line.y2::double precision - line.y1)
              ELSE false END
        GROUP BY side.sector_id
        HAVING count(*) % 2 = 1
        ORDER BY side.sector_id
        LIMIT 1
    );
END;
$$;
