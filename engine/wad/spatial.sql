CREATE TYPE doom._wad_bsp_leaf AS (
    sector_id integer,
    line_ids integer[]
);

CREATE TYPE doom._wad_bsp_node AS (
    x integer,
    y integer,
    dx integer,
    dy integer,
    right_child integer,
    left_child integer,
    right_top integer,
    right_bottom integer,
    right_left integer,
    right_right integer,
    left_top integer,
    left_bottom integer,
    left_left integer,
    left_right integer
);

CREATE TABLE doom.wad_bsp (
    level_id bigint PRIMARY KEY REFERENCES doom.levels ON DELETE CASCADE,
    nodes doom._wad_bsp_node[] NOT NULL,
    leaves doom._wad_bsp_leaf[] NOT NULL,
    has_line_grid boolean NOT NULL
);

CREATE TABLE doom.wad_line_blocks (
    level_id bigint NOT NULL REFERENCES doom.wad_bsp ON DELETE CASCADE,
    block_x integer NOT NULL,
    block_y integer NOT NULL,
    line_ids integer[] NOT NULL,
    PRIMARY KEY (level_id, block_x, block_y)
);

CREATE FUNCTION doom._invalidate_wad_spatial()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'TRUNCATE' THEN
        DELETE FROM doom.wad_bsp;
        RETURN NULL;
    END IF;
    IF TG_OP = 'INSERT' THEN
        DELETE FROM doom.wad_bsp AS bsp WHERE bsp.level_id = NEW.level_id;
    ELSIF TG_OP = 'DELETE' THEN
        DELETE FROM doom.wad_bsp AS bsp WHERE bsp.level_id = OLD.level_id;
    ELSIF (OLD.level_id, OLD.line_id, OLD.x1, OLD.y1, OLD.x2, OLD.y2, OLD.front_sector_id, OLD.back_sector_id)
        IS DISTINCT FROM
          (NEW.level_id, NEW.line_id, NEW.x1, NEW.y1, NEW.x2, NEW.y2, NEW.front_sector_id, NEW.back_sector_id)
    THEN
        DELETE FROM doom.wad_bsp AS bsp WHERE bsp.level_id IN (OLD.level_id, NEW.level_id);
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER lines_invalidate_wad_spatial
AFTER INSERT OR DELETE OR UPDATE OF level_id, line_id, x1, y1, x2, y2, front_sector_id, back_sector_id
ON doom.lines FOR EACH ROW EXECUTE FUNCTION doom._invalidate_wad_spatial();

CREATE TRIGGER lines_invalidate_wad_spatial_truncate
AFTER TRUNCATE ON doom.lines FOR EACH STATEMENT EXECUTE FUNCTION doom._invalidate_wad_spatial();

CREATE FUNCTION doom._compile_wad_spatial(
    p_level_id bigint, p_vertex_x integer[], p_vertex_y integer[],
    p_segs bytea, p_leaves bytea, p_nodes bytea
)
RETURNS void
LANGUAGE plpgsql STRICT
AS $$
DECLARE
    seg_count integer := octet_length(p_segs) / 12;
    leaf_count integer := octet_length(p_leaves) / 4;
    node_count integer := octet_length(p_nodes) / 28;
    nodes doom._wad_bsp_node[] := '{}';
    leaves doom._wad_bsp_leaf[] := '{}';
    segment_lines integer[];
    segment_sectors integer[];
    leaf doom._wad_bsp_leaf;
    -- Leaf slots precede node slots. Bounds include complete source linedefs.
    lefts integer[] := '{}';
    bottoms integer[] := '{}';
    rights integer[] := '{}';
    tops integer[] := '{}';
    used boolean[];
    first_segment integer := 1;
    last_segment integer;
    offset_bytes integer;
    right_child integer;
    left_child integer;
    right_slot integer;
    left_slot integer;
    split_dx integer;
    split_dy integer;
    bound_left integer;
    bound_bottom integer;
    bound_right integer;
    bound_top integer;
    source_count integer;
    has_grid boolean;
BEGIN
    -- The core importer can accept a map whose optional acceleration lumps are absent.
    IF octet_length(p_segs) % 12 <> 0 OR octet_length(p_leaves) % 4 <> 0 OR octet_length(p_nodes) % 28 <> 0
        OR seg_count NOT BETWEEN 1 AND 65536 OR leaf_count NOT BETWEEN 1 AND 32768
        OR node_count <> leaf_count - 1
    THEN
        RETURN;
    END IF;

    SELECT array_agg(decoded.line_id ORDER BY decoded.id),
           array_agg(CASE decoded.side WHEN 0 THEN line.front_sector_id ELSE line.back_sector_id END
                     ORDER BY decoded.id),
           count(DISTINCT decoded.line_id)
    INTO segment_lines, segment_sectors, source_count
    FROM generate_series(0, seg_count - 1) AS seg(id)
    CROSS JOIN LATERAL (
        SELECT seg.id, doom.wad_u16(p_segs, seg.id * 12) + 1 AS start_vertex,
               doom.wad_u16(p_segs, seg.id * 12 + 2) + 1 AS end_vertex,
               doom.wad_u16(p_segs, seg.id * 12 + 6) AS line_id,
               doom.wad_u16(p_segs, seg.id * 12 + 8) AS side
    ) AS decoded
    JOIN doom.lines AS line ON line.level_id = p_level_id AND line.line_id = decoded.line_id
    WHERE decoded.start_vertex <= cardinality(p_vertex_x) AND decoded.end_vertex <= cardinality(p_vertex_x)
      AND (p_vertex_x[decoded.start_vertex], p_vertex_y[decoded.start_vertex])
           <> (p_vertex_x[decoded.end_vertex], p_vertex_y[decoded.end_vertex])
      AND (decoded.side = 0 OR (decoded.side = 1 AND line.back_sector_id IS NOT NULL));

    IF cardinality(segment_lines) IS DISTINCT FROM seg_count
        OR source_count <> (SELECT count(*) FROM doom.lines WHERE level_id = p_level_id)
    THEN
        RETURN;
    END IF;

    FOR leaf_id IN 0 .. leaf_count - 1 LOOP
        offset_bytes := leaf_id * 4;
        last_segment := first_segment + doom.wad_u16(p_leaves, offset_bytes) - 1;
        IF first_segment <> doom.wad_u16(p_leaves, offset_bytes + 2) + 1
            OR last_segment < first_segment OR last_segment > seg_count
        THEN
            RETURN;
        END IF;

        SELECT array_agg(line.line_id ORDER BY line.line_id),
               min(least(line.x1, line.x2)), min(least(line.y1, line.y2)),
               max(greatest(line.x1, line.x2)), max(greatest(line.y1, line.y2))
        INTO leaf.line_ids, bound_left, bound_bottom, bound_right, bound_top
        FROM doom.lines AS line
        JOIN (SELECT DISTINCT seg.line_id FROM unnest(segment_lines[first_segment:last_segment]) AS seg(line_id)) AS src
          USING (line_id)
        WHERE line.level_id = p_level_id;
        lefts := array_append(lefts, bound_left);
        bottoms := array_append(bottoms, bound_bottom);
        rights := array_append(rights, bound_right);
        tops := array_append(tops, bound_top);
        leaf.sector_id := segment_sectors[first_segment];
        leaves := array_append(leaves, leaf);
        first_segment := last_segment + 1;
    END LOOP;
    IF first_segment <> seg_count + 1 THEN
        RETURN;
    END IF;

    used := array_fill(false, ARRAY[leaf_count + node_count]);
    FOR node_id IN 0 .. node_count - 1 LOOP
        offset_bytes := node_id * 28;
        split_dx := doom.wad_i16(p_nodes, offset_bytes + 4);
        split_dy := doom.wad_i16(p_nodes, offset_bytes + 6);
        right_child := doom.wad_u16(p_nodes, offset_bytes + 24);
        left_child := doom.wad_u16(p_nodes, offset_bytes + 26);
        IF right_child >= 32768 THEN
            right_child := ~(right_child - 32768);
        END IF;
        IF left_child >= 32768 THEN
            left_child := ~(left_child - 32768);
        END IF;
        IF (split_dx = 0 AND split_dy = 0) OR right_child NOT BETWEEN -leaf_count AND node_id - 1
            OR left_child NOT BETWEEN -leaf_count AND node_id - 1
        THEN
            RETURN;
        END IF;
        right_slot := CASE WHEN right_child < 0 THEN -right_child ELSE leaf_count + right_child + 1 END;
        left_slot := CASE WHEN left_child < 0 THEN -left_child ELSE leaf_count + left_child + 1 END;
        IF right_slot = left_slot OR used[right_slot] OR used[left_slot] THEN
            RETURN;
        END IF;
        used[right_slot] := true;
        used[left_slot] := true;
        nodes := array_append(nodes, ROW(
            doom.wad_i16(p_nodes, offset_bytes), doom.wad_i16(p_nodes, offset_bytes + 2), split_dx, split_dy,
            right_child, left_child, tops[right_slot], bottoms[right_slot], lefts[right_slot], rights[right_slot],
            tops[left_slot], bottoms[left_slot], lefts[left_slot], rights[left_slot]
        )::doom._wad_bsp_node);
        lefts[leaf_count + node_id + 1] := least(lefts[right_slot], lefts[left_slot]);
        bottoms[leaf_count + node_id + 1] := least(bottoms[right_slot], bottoms[left_slot]);
        rights[leaf_count + node_id + 1] := greatest(rights[right_slot], rights[left_slot]);
        tops[leaf_count + node_id + 1] := greatest(tops[right_slot], tops[left_slot]);
    END LOOP;

    -- Bound import work even for a classic map with many map-wide segments.
    SELECT sum((floor(greatest(x1, x2) / 128.0) - floor(least(x1, x2) / 128.0) + 1)
             * (floor(greatest(y1, y2) / 128.0) - floor(least(y1, y2) / 128.0) + 1)) <= 250000
    INTO has_grid
    FROM doom.lines AS line WHERE line.level_id = p_level_id;

    INSERT INTO doom.wad_bsp (level_id, nodes, leaves, has_line_grid)
    VALUES (p_level_id, nodes, leaves, has_grid);
    IF has_grid THEN
        INSERT INTO doom.wad_line_blocks (level_id, block_x, block_y, line_ids)
        SELECT p_level_id, x.block, y.block, array_agg(line.line_id ORDER BY line.line_id)
        FROM doom.lines AS line
        CROSS JOIN LATERAL generate_series(floor(least(line.x1, line.x2) / 128.0)::integer,
                                           floor(greatest(line.x1, line.x2) / 128.0)::integer) AS x(block)
        CROSS JOIN LATERAL generate_series(floor(least(line.y1, line.y2) / 128.0)::integer,
                                           floor(greatest(line.y1, line.y2) / 128.0)::integer) AS y(block)
        WHERE line.level_id = p_level_id
        GROUP BY x.block, y.block;
    END IF;
END;
$$;

CREATE FUNCTION doom._wad_line_candidates(
    p_level_id bigint, p_xmin double precision, p_ymin double precision,
    p_xmax double precision, p_ymax double precision
)
RETURNS integer[]
LANGUAGE plpgsql STABLE STRICT PARALLEL SAFE
AS $$
DECLARE
    first_block_x integer;
    first_block_y integer;
    last_block_x integer;
    last_block_y integer;
    candidates integer[];
BEGIN
    IF NOT (p_xmin BETWEEN -32768 AND p_xmax AND p_xmax <= 32767
            AND p_ymin BETWEEN -32768 AND p_ymax AND p_ymax <= 32767)
        OR NOT EXISTS (SELECT FROM doom.wad_bsp WHERE level_id = p_level_id AND has_line_grid)
    THEN
        RETURN NULL;
    END IF;
    first_block_x := floor(p_xmin / 128)::integer;
    first_block_y := floor(p_ymin / 128)::integer;
    last_block_x := floor(p_xmax / 128)::integer;
    last_block_y := floor(p_ymax / 128)::integer;
    IF (last_block_x - first_block_x + 1) * (last_block_y - first_block_y + 1) > 256 THEN
        RETURN NULL;
    END IF;
    IF first_block_x = last_block_x AND first_block_y = last_block_y THEN
        SELECT block.line_ids INTO candidates
        FROM doom.wad_line_blocks AS block
        WHERE block.level_id = p_level_id AND block.block_x = first_block_x AND block.block_y = first_block_y;
    ELSE
        SELECT array_agg(DISTINCT line.id ORDER BY line.id) INTO candidates
        FROM doom.wad_line_blocks AS block
        CROSS JOIN LATERAL unnest(block.line_ids) AS line(id)
        WHERE block.level_id = p_level_id AND block.block_x BETWEEN first_block_x AND last_block_x
          AND block.block_y BETWEEN first_block_y AND last_block_y;
    END IF;
    RETURN coalesce(candidates, '{}'::integer[]);
END;
$$;
