CREATE TABLE doom._frame_geometry (
    level_id bigint PRIMARY KEY REFERENCES doom.levels ON DELETE CASCADE,
    -- Four partition values, two children, two four-coordinate boxes per node.
    nodes integer[] NOT NULL,
    -- First and last inclusive seg ID for each leaf.
    leaves integer[] NOT NULL,
    wall_heights jsonb NOT NULL
);

CREATE TABLE doom._frame_segments (
    level_id bigint NOT NULL REFERENCES doom._frame_geometry ON DELETE CASCADE,
    seg_id integer NOT NULL,
    x1 integer NOT NULL, y1 integer NOT NULL,
    x2 integer NOT NULL, y2 integer NOT NULL,
    front_sector_id integer NOT NULL, back_sector_id integer,
    length double precision NOT NULL,
    x_offset integer NOT NULL, y_offset integer NOT NULL,
    flags integer NOT NULL,
    upper_material text, lower_material text, middle_material text,
    PRIMARY KEY (level_id,seg_id)
);

CREATE TABLE doom._frame_posts (
    level_id bigint NOT NULL REFERENCES doom.levels ON DELETE CASCADE,
    kind text NOT NULL,
    name text NOT NULL,
    source_x integer NOT NULL,
    rows int4multirange NOT NULL,
    PRIMARY KEY (level_id,kind,name,source_x)
);

CREATE FUNCTION doom.compile_frame_assets(p_level_id bigint)
RETURNS void LANGUAGE sql VOLATILE STRICT AS $$
    INSERT INTO doom._frame_geometry(level_id, nodes, leaves, wall_heights)
    SELECT p_level_id,
        coalesce((SELECT array_agg(field.value ORDER BY node.node_id, field.ordinal)
            FROM doom.wad_bsp_nodes AS node CROSS JOIN LATERAL unnest(ARRAY[
                node.x,node.y,node.dx,node.dy,node.right_child,node.left_child,
                node.right_left,node.right_right,node.right_bottom,node.right_top,
                node.left_left,node.left_right,node.left_bottom,node.left_top
            ]) WITH ORDINALITY AS field(value,ordinal) WHERE node.level_id = p_level_id), '{}'::integer[]),
        coalesce((SELECT array_agg(field.value ORDER BY leaf.subsector_id, field.ordinal)
            FROM doom.wad_subsectors AS leaf CROSS JOIN LATERAL unnest(
                ARRAY[leaf.first_seg_id,leaf.first_seg_id + leaf.seg_count - 1]
            ) WITH ORDINALITY AS field(value,ordinal) WHERE leaf.level_id = p_level_id), '{}'::integer[]),
        coalesce((SELECT jsonb_object_agg(material.name,material.height) FROM doom.level_materials AS material
            WHERE material.level_id = p_level_id AND material.surface_kind = 'wall'), '{}'::jsonb)
    ON CONFLICT (level_id) DO UPDATE SET nodes = excluded.nodes, leaves = excluded.leaves,
        wall_heights = excluded.wall_heights;

    DELETE FROM doom._frame_segments WHERE level_id = p_level_id;
    INSERT INTO doom._frame_segments
    SELECT p_level_id,seg.seg_id,seg.x1,seg.y1,seg.x2,seg.y2,seg.front_sector_id,seg.back_sector_id,
        sqrt((seg.x2-seg.x1::float8)^2+(seg.y2-seg.y1::float8)^2),seg."offset"+face.x_offset,face.y_offset,
        line.flags,face.upper_material,face.lower_material,face.middle_material
    FROM doom.wad_segs AS seg
    JOIN doom.lines AS line ON line.level_id = p_level_id AND line.line_id = seg.line_id
    JOIN doom.wad_sidedefs AS face ON face.level_id = p_level_id AND face.side_id = seg.side_id
    WHERE seg.level_id = p_level_id
        AND (seg.front_sector_id IS DISTINCT FROM seg.back_sector_id OR face.middle_material IS NOT NULL);

    DELETE FROM doom._frame_posts WHERE level_id = p_level_id;
    INSERT INTO doom._frame_posts(level_id,kind,name,source_x,rows)
    SELECT p_level_id, material.surface_kind, material.name, column_x.x,
        range_agg(int4range(texel.y,texel.y + 1))
    FROM (SELECT model.surface_kind,model.name,model.width,model.height,
            substring(model.coverage FROM 1) AS coverage
        FROM doom.level_materials AS model
        WHERE model.level_id = p_level_id AND NOT model.opaque AND model.surface_kind IN ('wall','sprite')
        OFFSET 0
    ) AS material
    CROSS JOIN LATERAL generate_series(0,material.width - 1) AS column_x(x)
    CROSS JOIN LATERAL generate_series(0,material.height - 1) AS texel(y)
    WHERE get_byte(material.coverage,column_x.x * material.height + texel.y) <> 0
    GROUP BY material.surface_kind, material.name, column_x.x;
$$;

CREATE FUNCTION doom._frame_seg_ids(
    p_nodes integer[], p_leaves integer[],
    p_x double precision, p_y double precision, p_fx double precision, p_fy double precision
) RETURNS integer[] LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
    stack integer[] := ARRAY[cardinality(p_nodes) / 14 - 1];
    stack_size integer := 1;
    child integer;
    node_index integer;
    leaf_index integer;
    seg_id integer;
    on_right boolean;
    check_right boolean;
    side_index integer;
    bounds_index integer;
    xl double precision;
    xr double precision;
    yb double precision;
    yt double precision;
    left_x double precision := p_fx+p_fy;
    left_y double precision := p_fy-p_fx;
    right_x double precision := p_fx-p_fy;
    right_y double precision := p_fy+p_fx;
    ids integer[] := '{}';
BEGIN
    IF cardinality(p_leaves) = 0 THEN
        RETURN ids;
    END IF;
    WHILE stack_size > 0 LOOP
        child := stack[stack_size];
        stack_size := stack_size - 1;
        IF child < 0 THEN
            leaf_index := -2*child - 1;
            FOR seg_id IN p_leaves[leaf_index]..p_leaves[leaf_index + 1] LOOP
                ids := array_append(ids, seg_id);
            END LOOP;
            CONTINUE;
        END IF;

        node_index := child * 14;
        on_right := (p_x - p_nodes[node_index + 1]) * p_nodes[node_index + 4]
            >= (p_y - p_nodes[node_index + 2]) * p_nodes[node_index + 3];
        -- Push the far side first so the near side is visited first.
        -- Each wedge half-plane can reject an AABB only when every corner fails it.
        FOR side_index IN 0..1 LOOP
            check_right := on_right = (side_index = 1);
            bounds_index := node_index + CASE WHEN check_right THEN 6 ELSE 10 END;
            xl := p_nodes[bounds_index+1] - p_x;
            xr := p_nodes[bounds_index+2] - p_x;
            yb := p_nodes[bounds_index+3] - p_y;
            yt := p_nodes[bounds_index+4] - p_y;
            IF greatest(xl*p_fx,xr*p_fx)+greatest(yb*p_fy,yt*p_fy) >= 0.001
                AND greatest(xl*left_x,xr*left_x)+greatest(yb*left_y,yt*left_y) >= -1e-9
                AND greatest(xl*right_x,xr*right_x)+greatest(yb*right_y,yt*right_y) >= -1e-9
            THEN
                stack_size := stack_size + 1;
                stack[stack_size] := p_nodes[node_index + CASE WHEN check_right THEN 5 ELSE 6 END];
            END IF;
        END LOOP;
    END LOOP;
    RETURN ids;
END;
$$;

CREATE TYPE doom._frame_sector AS (
    sector_id integer, floor_height integer, ceiling_height integer,
    floor_material text, ceiling_material text, light integer
);

CREATE TYPE doom._frame_mapping AS (
    kind text, name text, shade integer, u double precision, v double precision,
    du double precision, dv double precision, depth double precision
);

CREATE TYPE doom._frame_span AS (
    x integer, y1 integer, y2 integer, sample doom._frame_mapping
);

CREATE FUNCTION doom._frame_light(p_light integer, p_depth double precision)
RETURNS integer LANGUAGE sql IMMUTABLE PARALLEL SAFE
RETURN greatest(0, least(31, (255 - p_light) / 8 + least(8, floor(p_depth / 192)::integer)));

CREATE FUNCTION doom._frame_run(p_at integer, p_vertical boolean, p_shade integer, p_colors bytea)
RETURNS bytea LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
RETURN int2send((p_at | CASE WHEN p_vertical THEN 16384 ELSE 0 END)::smallint)
    || set_byte(set_byte('\x0000'::bytea, 0, octet_length(p_colors)), 1, p_shade) || p_colors;

CREATE FUNCTION doom.frame_palette(p_game_id bigint, p_palette_id integer)
RETURNS bytea LANGUAGE sql STABLE STRICT PARALLEL SAFE
RETURN (
    SELECT string_agg(substring(palette.playpal FROM p_palette_id * 768
        + get_byte(palette.colormap, color.i) * 3 + 1 FOR 3), ''::bytea ORDER BY color.i)
    FROM doom.games AS game
    JOIN doom.level_palettes AS palette USING (level_id)
    CROSS JOIN LATERAL generate_series(0, octet_length(palette.colormap) - 1) AS color(i)
    WHERE game.game_id = p_game_id AND p_palette_id >= 0
        AND p_palette_id < octet_length(palette.playpal) / 768
);

CREATE FUNCTION doom._frame_hits(
    p_game_id bigint, p_level_id bigint, p_camera_sector integer, p_segments integer[],
    p_x double precision, p_y double precision, p_fx double precision, p_fy double precision
) RETURNS TABLE (
    x integer, depth double precision, hit_id bigint, is_sprite boolean,
    near_sector integer, far_sector integer, upper_name text, lower_name text, middle_name text,
    flags integer, u double precision, y_offset integer, low_z double precision, high_z double precision
) LANGUAGE sql STABLE PARALLEL SAFE AS $$
    WITH RECURSIVE camera_segs AS MATERIALIZED (
        SELECT seg.seg_id,seg.front_sector_id,seg.back_sector_id,
            seg.length,seg.x_offset,seg.y_offset,seg.flags,seg.upper_material,seg.lower_material,seg.middle_material,
            (seg.x1 - p_x)*p_fx + (seg.y1 - p_y)*p_fy AS az,
            (seg.x2 - p_x)*p_fx + (seg.y2 - p_y)*p_fy AS bz,
            (seg.x1 - p_x)*p_fy - (seg.y1 - p_y)*p_fx AS ar,
            (seg.x2 - p_x)*p_fy - (seg.y2 - p_y)*p_fx AS br
        FROM unnest(p_segments) AS visible(id)
        JOIN doom._frame_segments AS seg ON seg.level_id = p_level_id AND seg.seg_id = visible.id
    ), wall_projections AS MATERIALIZED (
        SELECT seg.*, seg.bz - seg.az AS dz, seg.br - seg.ar AS dr,
            seg.az * seg.br - seg.ar * seg.bz AS numerator,
            CASE WHEN seg.az >= 0.001 THEN seg.ar / seg.az
                ELSE (seg.ar + (seg.br - seg.ar)*(0.001 - seg.az)/nullif(seg.bz - seg.az, 0)) / 0.001 END AS sa,
            CASE WHEN seg.bz >= 0.001 THEN seg.br / seg.bz
                ELSE (seg.br + (seg.ar - seg.br)*(0.001 - seg.bz)/nullif(seg.az - seg.bz, 0)) / 0.001 END AS sb
        FROM camera_segs AS seg
        WHERE greatest(seg.az, seg.bz) >= 0.001
            AND greatest(seg.az + seg.ar, seg.bz + seg.br) >= -1e-9
            AND greatest(seg.az - seg.ar, seg.bz - seg.br) >= -1e-9
    ), walls AS MATERIALIZED (
        SELECT wall.*,
            greatest(0, least(160, floor(80 * (1 + least(wall.sa,wall.sb)) - 0.5 + 1e-9) + 1))::integer AS first_x,
            greatest(-1, least(159, floor(80 * (1 + greatest(wall.sa,wall.sb)) - 0.5 + 1e-9)))::integer AS last_x
        FROM wall_projections AS wall
        WHERE wall.numerator > 0
    ), walk(x, slope, depth, seg_id, next_sector, determinant) AS (
        SELECT col.x, (col.x - 79.5::float8)/80, 0::float8, -1, p_camera_sector, NULL::float8
        FROM generate_series(0,159) AS col(x)
        UNION ALL
        -- Follow the sector on each ray instead of generating every projected line-column pair.
        SELECT next.x, next.slope, next.depth, next.seg_id, next.back_sector_id, next.determinant
        FROM (
            SELECT DISTINCT ON (prior.x) prior.x, prior.slope, z.depth, wall.seg_id,
                wall.back_sector_id, ray.determinant
            FROM walk AS prior
            JOIN walls AS wall ON wall.front_sector_id = prior.next_sector AND prior.x BETWEEN wall.first_x AND wall.last_x
            CROSS JOIN LATERAL (
                SELECT wall.dr - prior.slope*wall.dz AS determinant
            ) AS ray
            CROSS JOIN LATERAL (SELECT wall.numerator / nullif(ray.determinant,0) AS depth) AS z
            WHERE z.depth >= 0.001 AND (z.depth,wall.seg_id) > (prior.depth,prior.seg_id)
            ORDER BY prior.x, z.depth, wall.seg_id
        ) AS next
    ), crossings AS (
        SELECT pass.x, pass.depth, wall.seg_id, wall.front_sector_id, wall.back_sector_id,
            wall.upper_material, wall.lower_material, wall.middle_material, wall.flags,wall.y_offset,
            wall.x_offset + wall.length * greatest(0,least(1,
                (pass.slope*wall.az - wall.ar) / nullif(pass.determinant,0))) AS u
        FROM walk AS pass
        JOIN walls AS wall ON wall.seg_id = pass.seg_id
    ), view_sprites AS MATERIALIZED (
        SELECT actor.actor_id, actor.sector_id, actor.z, material.name, material.height, material.width,
            material.left_offset, material.top_offset,
            (actor.x - p_x)*p_fx + (actor.y - p_y)*p_fy AS depth,
            (actor.x - p_x)*p_fy - (actor.y - p_y)*p_fx AS across
        FROM doom.actors AS actor
        JOIN doom.level_materials AS material ON material.level_id = p_level_id
            AND material.surface_kind = 'sprite' AND material.name = actor.sprite_material
        WHERE actor.game_id = p_game_id AND actor.kind <> 'player'
    ), sprite_columns AS (
        SELECT col.x, actor.depth, actor.actor_id, actor.sector_id, actor.name,
            (col.x - 79.5::float8) * actor.depth/80::float8 - (actor.across - actor.left_offset) AS u,
            actor.z + actor.top_offset - actor.height AS low_z, actor.z + actor.top_offset AS high_z
        FROM view_sprites AS actor
        CROSS JOIN LATERAL generate_series(
            greatest(0, least(160, ceil(79.5 + 80 * (actor.across - actor.left_offset)
                / greatest(0.001, actor.depth))))::integer,
            greatest(-1, least(159, ceil(79.5 + 80 * (actor.across - actor.left_offset + actor.width)
                / greatest(0.001, actor.depth)) - 1))::integer
        ) AS col(x)
        WHERE actor.depth >= 0.001
    )
    SELECT hit.x, hit.depth, hit.seg_id::bigint, false, hit.front_sector_id, hit.back_sector_id,
        hit.upper_material, hit.lower_material, hit.middle_material, hit.flags, hit.u, hit.y_offset, NULL::float8, NULL::float8
    FROM crossings AS hit
    UNION ALL
    SELECT sprite.x, sprite.depth, sprite.actor_id, true, sprite.sector_id, NULL,
        NULL, NULL, sprite.name, 0, sprite.u, 0, sprite.low_z, sprite.high_z
    FROM sprite_columns AS sprite
    UNION ALL
    SELECT col.x, NULL, NULL, false, NULL, NULL, NULL, NULL, NULL, 0, NULL, 0, NULL, NULL
    FROM generate_series(0,159) AS col(x)
    ORDER BY 1, 2 NULLS LAST, 4, 3;
$$;

CREATE FUNCTION doom._frame_y(p_eye double precision, p_z double precision, p_scale double precision,
    p_first integer, p_last integer)
RETURNS integer LANGUAGE sql IMMUTABLE PARALLEL SAFE
RETURN greatest(p_first, least(p_last, ceil(49.5 + (p_eye - p_z) * p_scale)))::integer;

CREATE FUNCTION doom._frame_composite(p_level_id bigint, p_base doom._frame_span[], p_layers doom._frame_span[])
RETURNS doom._frame_span[] LANGUAGE sql STABLE PARALLEL SAFE AS $$
    WITH layers AS MATERIALIZED (
        SELECT span.x, span.y1, span.y2, span.sample, span.seq,
            model.surface_kind AS kind, model.height, model.width, model.opaque,
            CASE WHEN (span.sample).kind = 'mask'
                THEN (floor((span.sample).u)::bigint % model.width + model.width) % model.width
                ELSE floor((span.sample).u)::bigint END AS source_x
        FROM unnest(p_layers) WITH ORDINALITY AS span(x,y1,y2,sample,seq)
        JOIN doom.level_materials AS model ON model.level_id = p_level_id
            AND model.surface_kind = CASE WHEN (span.sample).kind = 'mask' THEN 'wall' ELSE 'sprite' END
            AND model.name = (span.sample).name
    ), masks AS MATERIALIZED (
        SELECT layer.x, layer.sample, layer.seq, range_agg(int4range(clip.first_y,clip.last_y)) AS rows
        FROM layers AS layer
        LEFT JOIN doom._frame_posts AS compiled ON NOT layer.opaque
            AND compiled.level_id = p_level_id AND compiled.kind = layer.kind
            AND compiled.name = (layer.sample).name AND compiled.source_x = layer.source_x
        CROSS JOIN LATERAL unnest(CASE WHEN layer.opaque
            THEN int4multirange(int4range(0,layer.height)) ELSE compiled.rows END) AS post(rows)
        CROSS JOIN LATERAL (
            SELECT greatest(layer.y1, least(layer.y2,
                ceil((lower(post.rows) - (layer.sample).v) / (layer.sample).dv)))::integer AS first_y,
                greatest(layer.y1, least(layer.y2,
                ceil((upper(post.rows) - (layer.sample).v) / (layer.sample).dv)))::integer AS last_y
        ) AS clip
        WHERE layer.source_x >= 0 AND layer.source_x < layer.width AND clip.first_y < clip.last_y
        GROUP BY layer.x, layer.sample, layer.seq
    ), covered AS (
        SELECT x, range_agg(rows) AS rows FROM masks GROUP BY x
    ), visible AS (
        SELECT x, sample, rows - coalesce(range_agg(rows) OVER (
            PARTITION BY x ORDER BY seq ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ), '{}'::int4multirange) AS rows
        FROM masks
        UNION ALL
        SELECT span.x, span.sample,
            int4multirange(int4range(span.y1,span.y2)) - coalesce(covered.rows, '{}'::int4multirange)
        FROM unnest(p_base) AS span LEFT JOIN covered ON covered.x = span.x
    )
    SELECT array_agg(ROW(span.x,lower(piece.rows),upper(piece.rows),span.sample)::doom._frame_span)
    FROM visible AS span CROSS JOIN LATERAL unnest(span.rows) AS piece(rows);
$$;

CREATE TYPE doom._frame_draw AS (
    pixel integer, vertical boolean, length integer, shade integer,
    kind text, name text, u double precision, v double precision, du double precision, dv double precision
);

CREATE FUNCTION doom._frame_draws(
    p_spans doom._frame_span[], p_eye double precision, p_x double precision, p_y double precision,
    p_fx double precision, p_fy double precision
) RETURNS SETOF doom._frame_draw LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    WITH columns AS MATERIALIZED (
        SELECT span.x, span.sample, range_agg(int4range(span.y1,span.y2)) AS rows
        FROM unnest(p_spans) AS span
        WHERE (span.sample).kind = 'flat'
        GROUP BY span.x, span.sample
    ), events AS (
        SELECT coalesce(curr.x, prev.x + 1) AS x, pixel.y, delta.opens, coalesce(curr.sample,prev.sample) AS sample
        FROM columns AS prev FULL JOIN columns AS curr ON curr.x = prev.x + 1 AND curr.sample = prev.sample
        CROSS JOIN LATERAL (
            SELECT coalesce(curr.rows, '{}'::int4multirange) AS now,
                   coalesce(prev.rows, '{}'::int4multirange) AS before
        ) AS coverage
        CROSS JOIN LATERAL (VALUES (coverage.now - coverage.before, true),
            (coverage.before - coverage.now, false)) AS delta(rows,opens)
        CROSS JOIN LATERAL unnest(delta.rows) AS changed(rows)
        CROSS JOIN LATERAL generate_series(lower(changed.rows), upper(changed.rows) - 1) AS pixel(y)
    ), spans AS (
        SELECT event.*, lead(event.x) OVER (PARTITION BY event.y, event.sample ORDER BY event.x) AS x2
        FROM events AS event
    )
    SELECT span.y * 160 + span.x, false, span.x2 - span.x,
        doom._frame_light((span.sample).shade, projection.depth), 'flat', (span.sample).name,
        p_x + (p_fx + ray.slope*p_fy)*projection.depth,
        p_y + (p_fy - ray.slope*p_fx)*projection.depth,
        p_fy*projection.depth/80, -p_fx*projection.depth/80
    FROM spans AS span
    CROSS JOIN LATERAL (SELECT abs(p_eye - (span.sample).v)*80/abs(span.y - 49.5::float8) AS depth) AS projection
    CROSS JOIN LATERAL (SELECT (span.x - 79.5::float8)/80 AS slope) AS ray
    WHERE span.opens AND span.x < span.x2
    UNION ALL
    SELECT span.y1 * 160 + span.x, true, span.y2 - span.y1,
        (span.sample).shade, (span.sample).kind, (span.sample).name,
        (span.sample).u, (span.sample).v + (span.sample).dv * span.y1, 0, (span.sample).dv
    FROM unnest(p_spans) AS span
    WHERE (span.sample).kind <> 'flat';
$$;

-- A vertical run has one source column. Build eight samples as one network-order word.
CREATE FUNCTION doom._frame_column8(p_pixels bytea, p_column integer, p_mask integer,
    p_v double precision, p_dv double precision, p_at integer)
RETURNS bytea LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
RETURN int8send(
      (get_byte(p_pixels, p_column + (floor(p_v + p_at*p_dv)::bigint & p_mask)::integer)::bigint << 56)
    | (get_byte(p_pixels, p_column + (floor(p_v + (p_at+1)*p_dv)::bigint & p_mask)::integer)::bigint << 48)
    | (get_byte(p_pixels, p_column + (floor(p_v + (p_at+2)*p_dv)::bigint & p_mask)::integer)::bigint << 40)
    | (get_byte(p_pixels, p_column + (floor(p_v + (p_at+3)*p_dv)::bigint & p_mask)::integer)::bigint << 32)
    | (get_byte(p_pixels, p_column + (floor(p_v + (p_at+4)*p_dv)::bigint & p_mask)::integer)::bigint << 24)
    | (get_byte(p_pixels, p_column + (floor(p_v + (p_at+5)*p_dv)::bigint & p_mask)::integer)::bigint << 16)
    | (get_byte(p_pixels, p_column + (floor(p_v + (p_at+6)*p_dv)::bigint & p_mask)::integer)::bigint << 8)
    | get_byte(p_pixels, p_column + (floor(p_v + (p_at+7)*p_dv)::bigint & p_mask)::integer)::bigint
);

CREATE FUNCTION doom._frame_pack(
    p_level_id bigint, p_spans doom._frame_span[], p_eye double precision, p_x double precision, p_y double precision,
    p_fx double precision, p_fy double precision, p_max_shade integer
) RETURNS bytea LANGUAGE sql STABLE PARALLEL SAFE AS $$

    WITH draws AS MATERIALIZED (
        SELECT draw.*,
            CASE WHEN draw.kind IN ('wall','mask','sky') THEN 'wall' ELSE draw.kind END AS material_kind
        FROM doom._frame_draws(p_spans,p_eye,p_x,p_y,p_fx,p_fy) AS draw
    ), materials AS MATERIALIZED (
        SELECT material.surface_kind, material.name, material.width, material.height,
            (material.width & (material.width - 1)) = 0 AS power_width,
            (material.height & (material.height - 1)) = 0 AS power_height,
            substring(material.pixels FROM 1) AS pixels,
            material.surface_kind = 'flat' AND material.width = material.height
                AND material.width BETWEEN 4 AND 64
                AND EXISTS (SELECT FROM doom._flat_atlas AS atlas
                    WHERE atlas.level_id = p_level_id AND atlas.name = material.name) AS has_atlas
        FROM doom.level_materials AS material
        JOIN (SELECT DISTINCT material_kind,name FROM draws WHERE name IS NOT NULL) AS needed
            ON needed.material_kind = material.surface_kind AND needed.name = material.name
        WHERE material.level_id = p_level_id
    ), parts AS MATERIALIZED (
        SELECT draw.pixel,draw.vertical,draw.shade,draw.kind,draw.name,draw.material_kind,
            chunk.i,chunk.sample_count AS length,
            draw.u+chunk.i*draw.du AS u,draw.v+chunk.i*draw.dv AS v,
            draw.du,draw.dv,chunk.mip,chunk.dir_u,chunk.dir_v,chunk.page,chunk.first_byte
        FROM draws AS draw
        LEFT JOIN materials AS material ON material.surface_kind = draw.material_kind AND material.name = draw.name
        CROSS JOIN LATERAL doom._flat_atlas_chunks(
            CASE WHEN material.has_atlas AND draw.length >= 8 THEN material.width ELSE 0 END,
            draw.u,draw.v,draw.du,draw.dv,draw.length
        ) AS chunk
    ), atlas_pages AS MATERIALIZED (
        SELECT needed.name,needed.mip,needed.dir_u AS du,needed.dir_v AS dv,needed.page,found.colors
        FROM (SELECT DISTINCT name,mip,dir_u,dir_v,page FROM parts WHERE mip IS NOT NULL) AS needed
        CROSS JOIN LATERAL (
            SELECT substring(atlas.colors FROM 1) AS colors
            FROM doom._flat_atlas AS atlas
            WHERE atlas.level_id = p_level_id AND atlas.name = needed.name AND atlas.mip = needed.mip::smallint
                AND atlas.du = needed.dir_u::smallint AND atlas.dv = needed.dir_v::smallint AND atlas.page = needed.page
            OFFSET 0
        ) AS found
    ), addressed AS MATERIALIZED (
        -- Wide texel planes stay outside the atlas join and the output grouping sort.
        SELECT part.*,substring(page.colors FROM part.first_byte FOR part.length) AS atlas_colors
        FROM parts AS part
        LEFT JOIN atlas_pages AS page ON page.name = part.name AND page.mip = part.mip
            AND page.du = part.dir_u AND page.dv = part.dir_v AND page.page = part.page
    ), pieces AS MATERIALIZED (
        SELECT part.pixel,part.vertical,part.shade,part.i,part.atlas_colors
        FROM addressed AS part WHERE part.atlas_colors IS NOT NULL
        UNION ALL
        SELECT part.pixel,part.vertical,part.shade,part.i,
            CASE WHEN material.pixels IS NULL THEN decode(repeat('00',part.length),'hex')
                WHEN addresses.first_u = addresses.last_u AND addresses.first_v = addresses.last_v
                    THEN decode(repeat(encode(substring(material.pixels FROM
                        CASE WHEN part.vertical THEN source.u * material.height + source.v ELSE source.v * material.width + source.u END + 1
                        FOR 1),'hex'),part.length),'hex')
                WHEN part.vertical AND part.dv = 1 AND part.v = addresses.first_v::float8
                    AND source.v + part.length <= material.height
                    THEN substring(material.pixels FROM source.u * material.height + source.v + 1 FOR part.length)
                ELSE coalesce(packed.colors,samples.colors) END AS colors
        FROM addressed AS part
        LEFT JOIN materials AS material ON material.surface_kind = part.material_kind AND material.name = part.name
        CROSS JOIN LATERAL (
            SELECT floor(part.u)::bigint AS first_u, floor(part.v)::bigint AS first_v,
                floor(part.u + (part.length - 1)*part.du)::bigint AS last_u,
                floor(part.v + (part.length - 1)*part.dv)::bigint AS last_v
            OFFSET 0
        ) AS addresses
        CROSS JOIN LATERAL (
            SELECT (CASE WHEN material.power_width THEN addresses.first_u & (material.width - 1)
                ELSE (addresses.first_u % material.width + material.width) % material.width END)::integer AS u,
                (CASE WHEN material.power_height THEN addresses.first_v & (material.height - 1)
                    ELSE (addresses.first_v % material.height + material.height) % material.height END)::integer AS v
            OFFSET 0
        ) AS source
        LEFT JOIN LATERAL (
            SELECT string_agg(substring(doom._frame_column8(material.pixels,source.u*material.height,material.height-1,
                part.v,part.dv,block.i) FROM 1 FOR least(8,part.length-block.i)),''::bytea ORDER BY block.i) AS colors
            FROM generate_series(0,part.length-1,8) AS block(i)
            WHERE part.vertical AND material.power_height AND material.pixels IS NOT NULL
                AND addresses.first_v <> addresses.last_v
                AND NOT (part.dv = 1 AND part.v = addresses.first_v::float8 AND source.v + part.length <= material.height)
        ) AS packed ON true
        LEFT JOIN LATERAL (
            SELECT string_agg(substring(material.pixels FROM
                CASE WHEN part.vertical THEN source.u * material.height + texel.v
                    ELSE texel.v * material.width + texel.u END + 1 FOR 1
            ), ''::bytea ORDER BY pixel.i) AS colors
            FROM generate_series(0,part.length - 1) AS pixel(i)
            CROSS JOIN LATERAL (
                SELECT floor(part.u + pixel.i*part.du)::bigint AS u, floor(part.v + pixel.i*part.dv)::bigint AS v
                OFFSET 0
            ) AS offset_at
            CROSS JOIN LATERAL (
                SELECT (CASE WHEN material.power_width THEN offset_at.u & (material.width - 1)
                    ELSE (offset_at.u % material.width + material.width) % material.width END)::integer AS u,
                    (CASE WHEN material.power_height THEN offset_at.v & (material.height - 1)
                    ELSE (offset_at.v % material.height + material.height) % material.height END)::integer AS v
            ) AS texel
            WHERE material.pixels IS NOT NULL
                AND (NOT part.vertical OR NOT material.power_height)
                AND (addresses.first_u <> addresses.last_u OR addresses.first_v <> addresses.last_v)
                AND NOT (part.vertical AND part.dv = 1 AND part.v = addresses.first_v::float8
                    AND source.v + part.length <= material.height)
        ) AS samples ON true
        WHERE part.atlas_colors IS NULL
    ), runs AS (
        SELECT pixel,vertical,shade,string_agg(atlas_colors,''::bytea ORDER BY i) AS colors
        FROM pieces
        GROUP BY pixel,vertical,shade
    )
    SELECT string_agg(doom._frame_run(run.pixel,run.vertical,least(run.shade,p_max_shade),run.colors),
        ''::bytea ORDER BY run.pixel)
    FROM runs AS run;
$$;

CREATE FUNCTION doom.frame(p_game_id bigint, p_epoch bigint, p_slot bigint)
RETURNS TABLE(epoch bigint, tic bigint, slot bigint, palette_id integer, pixels bytea)
LANGUAGE plpgsql STABLE STRICT SET jit = off AS $$
DECLARE
    camera record;
    fx double precision;
    fy double precision;
    eye double precision;
    segment_ids integer[];
    sectors doom._frame_sector[];
    front_sector doom._frame_sector;
    back_sector doom._frame_sector;
    selected_sprite doom._frame_sector;
    wall_assets jsonb;
    geometry doom._frame_geometry;
    span_buffer doom._frame_span[] := '{}';
    overlays doom._frame_span[] := '{}';
    hit record;
    x integer := -1;
    clip_top integer;
    clip_bottom integer;
    top_y integer;
    bottom_y integer;
    opening_top integer;
    opening_bottom integer;
    opening_floor integer;
    opening_ceiling integer;
    scale double precision;
    dv double precision;
    wall_v double precision;
    shade integer;
    pegged_top integer;
    both_sky boolean;
    sky_name text;
    sky_u double precision;
    max_shade integer;
BEGIN
    SELECT game.epoch, game.tick_number, game.level_id, actor.x, actor.y, actor.z, actor.angle, actor.sector_id,
        level.name AS level_name
    INTO camera
    FROM doom.games AS game
    JOIN doom.levels AS level USING (level_id)
    JOIN doom.actors AS actor ON actor.game_id = game.game_id AND actor.kind = 'player'
    WHERE game.game_id = p_game_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'game % has no player camera', p_game_id USING ERRCODE = 'P0002';
    END IF;
    IF camera.epoch <> p_epoch OR p_slot < 0 THEN
        RAISE EXCEPTION 'invalid epoch or frame slot' USING ERRCODE = '22023';
    END IF;

    SELECT data.* INTO STRICT geometry FROM doom._frame_geometry AS data WHERE data.level_id = camera.level_id;
    SELECT coalesce(octet_length(pal.colormap)/256 - 1, 0) INTO STRICT max_shade
        FROM doom.level_palettes AS pal WHERE pal.level_id = camera.level_id;

    SELECT array_agg(ROW(sector.sector_id, coalesce(state.floor_height, sector.floor_height),
        coalesce(state.ceiling_height, sector.ceiling_height),
        sector.floor_material, sector.ceiling_material, sector.light_level
    )::doom._frame_sector ORDER BY sector.sector_id)
    INTO sectors
    FROM doom.sectors AS sector
    LEFT JOIN doom.sector_state AS state ON state.game_id = p_game_id AND state.sector_id = sector.sector_id
    WHERE sector.level_id = camera.level_id;

    wall_assets := geometry.wall_heights;

    fx := cos(camera.angle);
    fy := sin(camera.angle);
    -- Viewpoint height follows the live actor's feet, including stairs and lifts.
    eye := camera.z + 41;
    sky_name := doom._wad_sky_name(camera.level_name);
    segment_ids := doom._frame_seg_ids(geometry.nodes, geometry.leaves, camera.x, camera.y, fx, fy);

    FOR hit IN SELECT * FROM doom._frame_hits(p_game_id, camera.level_id, camera.sector_id, segment_ids, camera.x, camera.y, fx, fy)
    LOOP
        IF hit.x <> x THEN
            x := hit.x;
            front_sector := sectors[camera.sector_id + 1];
            clip_top := 0;
            clip_bottom := 100;
        END IF;
        IF clip_top >= clip_bottom THEN
            CONTINUE;
        END IF;

        IF hit.hit_id IS NULL THEN
            top_y := greatest(clip_top, least(clip_bottom, 50));
            bottom_y := top_y;
        ELSE
            scale := 80/hit.depth;
            dv := hit.depth/80;
            IF hit.is_sprite THEN
                -- Clip against nearer walls and openings, including actors whose patch reaches across a sector edge.
                selected_sprite := sectors[hit.near_sector + 1];
                top_y := doom._frame_y(eye, least(hit.high_z,selected_sprite.ceiling_height), scale,clip_top,clip_bottom);
                bottom_y := doom._frame_y(eye, greatest(hit.low_z,selected_sprite.floor_height), scale,clip_top,clip_bottom);
                IF top_y < bottom_y THEN
                    overlays := array_append(overlays, ROW(x,top_y,bottom_y,
                        ROW('sprite',hit.middle_name,doom._frame_light(selected_sprite.light,hit.depth),hit.u,
                            hit.high_z - eye - 49.5 * dv,0,dv,hit.depth)::doom._frame_mapping
                    )::doom._frame_span);
                END IF;
                CONTINUE;
            END IF;
            IF hit.near_sector IS DISTINCT FROM front_sector.sector_id THEN
                CONTINUE;
            END IF;

            top_y := doom._frame_y(eye,front_sector.ceiling_height,scale,clip_top,clip_bottom);
            bottom_y := doom._frame_y(eye,front_sector.floor_height,scale,clip_top,clip_bottom);
        END IF;

        IF clip_top < top_y THEN
            IF front_sector.ceiling_material = 'F_SKY1' THEN
                sky_u := (camera.angle - atan((x - 79.5)/80)) * 512 / pi();
                span_buffer := array_append(span_buffer, ROW(x,clip_top,top_y,
                    ROW('sky',sky_name,0,sky_u,0,0,1,0)::doom._frame_mapping)::doom._frame_span);
            ELSE
                span_buffer := array_append(span_buffer, ROW(x,clip_top,top_y,
                    ROW('flat',front_sector.ceiling_material,front_sector.light,0,front_sector.ceiling_height,0,0,0)
                        ::doom._frame_mapping)::doom._frame_span);
            END IF;
        END IF;
        IF bottom_y < clip_bottom THEN
            span_buffer := array_append(span_buffer, ROW(x,bottom_y,clip_bottom,
                ROW('flat',front_sector.floor_material,front_sector.light,0,front_sector.floor_height,0,0,0)
                    ::doom._frame_mapping)::doom._frame_span);
        END IF;
        IF hit.hit_id IS NULL THEN
            CONTINUE;
        END IF;

        back_sector := sectors[hit.far_sector + 1];
        shade := doom._frame_light(front_sector.light,hit.depth);
        wall_v := hit.y_offset - eye - 49.5 * dv;
        IF back_sector.sector_id IS NULL THEN
            IF top_y < bottom_y THEN
                pegged_top := CASE WHEN (hit.flags & 16) <> 0
                    THEN front_sector.floor_height + coalesce((wall_assets ->> hit.middle_name)::integer,0)
                    ELSE front_sector.ceiling_height END;
                span_buffer := array_append(span_buffer, ROW(x,top_y,bottom_y,
                    ROW('wall',hit.middle_name,shade,hit.u,wall_v + pegged_top,0,dv,hit.depth)
                        ::doom._frame_mapping)::doom._frame_span);
            END IF;
            clip_top := clip_bottom;
            CONTINUE;
        END IF;

        both_sky := front_sector.ceiling_material = 'F_SKY1' AND back_sector.ceiling_material = 'F_SKY1';
        opening_floor := greatest(front_sector.floor_height,back_sector.floor_height);
        opening_ceiling := least(front_sector.ceiling_height,back_sector.ceiling_height);
        opening_bottom := doom._frame_y(eye,opening_floor,scale,top_y,bottom_y);
        opening_top := doom._frame_y(eye,opening_ceiling,scale,top_y,bottom_y);
        IF both_sky AND opening_ceiling > opening_floor THEN
            opening_top := top_y;
        END IF;
        IF opening_top > opening_bottom THEN
            opening_top := opening_bottom;
        END IF;

        IF top_y < opening_top THEN
            pegged_top := CASE WHEN (hit.flags & 8) <> 0 THEN front_sector.ceiling_height
                ELSE back_sector.ceiling_height + coalesce((wall_assets ->> hit.upper_name)::integer,0) END;
            span_buffer := array_append(span_buffer, ROW(x,top_y,opening_top,
                ROW('wall',hit.upper_name,shade,hit.u,wall_v + pegged_top,0,dv,hit.depth)
                    ::doom._frame_mapping)::doom._frame_span);
        END IF;
        IF opening_bottom < bottom_y THEN
            pegged_top := CASE WHEN (hit.flags & 16) <> 0 THEN front_sector.ceiling_height
                ELSE back_sector.floor_height END;
            span_buffer := array_append(span_buffer, ROW(x,opening_bottom,bottom_y,
                ROW('wall',hit.lower_name,shade,hit.u,wall_v + pegged_top,0,dv,hit.depth)
                    ::doom._frame_mapping)::doom._frame_span);
        END IF;
        IF hit.middle_name IS NOT NULL AND opening_top < opening_bottom THEN
            pegged_top := CASE WHEN (hit.flags & 16) <> 0
                THEN opening_floor + coalesce((wall_assets ->> hit.middle_name)::integer,0) ELSE opening_ceiling END;
            overlays := array_append(overlays, ROW(x,opening_top,opening_bottom,
                ROW('mask',hit.middle_name,shade,hit.u,wall_v + pegged_top,0,dv,hit.depth)
                    ::doom._frame_mapping)::doom._frame_span);
        END IF;
        front_sector := back_sector;
        clip_top := opening_top;
        clip_bottom := opening_bottom;
    END LOOP;

    IF cardinality(overlays) > 0 THEN
        span_buffer := doom._frame_composite(camera.level_id,span_buffer,overlays);
    END IF;
    RETURN QUERY SELECT camera.epoch, camera.tick_number, p_slot, 0,
        doom._frame_pack(camera.level_id,span_buffer,eye,camera.x,camera.y,fx,fy,max_shade);
END;
$$;
