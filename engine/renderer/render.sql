CREATE TYPE doom._render_sector AS (
    sector_id integer,
    floor_height integer,
    ceiling_height integer,
    floor_rgb bytea,
    ceiling_rgb bytea
);

CREATE TYPE doom._render_span AS (
    column_x integer,
    row_start integer,
    row_end integer,
    rgb bytea
);

CREATE FUNCTION doom._render_rgb(p_color integer, p_light integer)
RETURNS bytea
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
RETURN decode(lpad(to_hex(
    (((((p_color >> 16) & 255) * p_light + 127) / 255) << 16)
    | (((((p_color >> 8) & 255) * p_light + 127) / 255) << 8)
    | (((p_color & 255) * p_light + 127) / 255)
), 6, '0'), 'hex');

-- Actor spans arrive front to back. Subtract nearer spans before unpacking the
-- packed RGB rows, so neither overdraw nor sorting scales with actor pixel count.
CREATE FUNCTION doom._render_layer_actors(p_world doom._render_span[], p_actors doom._render_span[])
RETURNS doom._render_span[]
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
RETURN (
    WITH actor_rows AS MATERIALIZED (
        SELECT column_x, rgb, depth_order, int4range(row_start, row_end) AS rows
        FROM unnest(p_actors) WITH ORDINALITY AS actor(column_x, row_start, row_end, rgb, depth_order)
    ), covered_rows AS (
        SELECT column_x, range_agg(rows) AS mask
        FROM actor_rows
        GROUP BY column_x
    ), actor_masks AS (
        SELECT column_x, rows, rgb,
               range_agg(rows) OVER (PARTITION BY column_x ORDER BY depth_order
                   ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS mask
        FROM actor_rows
    ), pieces AS (
        SELECT actor.column_x, visible.rows, actor.rgb
        FROM actor_masks AS actor
        CROSS JOIN LATERAL unnest(int4multirange(actor.rows)
            - coalesce(actor.mask, '{}'::int4multirange)) AS visible(rows)
        UNION ALL
        SELECT base.column_x, visible.rows, base.rgb
        FROM unnest(p_world) AS base
        LEFT JOIN covered_rows AS covered ON covered.column_x = base.column_x
        CROSS JOIN LATERAL unnest(int4multirange(int4range(base.row_start, base.row_end))
            - coalesce(covered.mask, '{}'::int4multirange)) AS visible(rows)
    )
    SELECT array_agg(ROW(column_x, lower(rows), upper(rows), rgb)::doom._render_span)
    FROM pieces
);

-- Renders RGB888 from the current transaction snapshot. Rows run top to bottom.
CREATE FUNCTION doom.render(p_game_id bigint, p_width integer, p_height integer)
RETURNS bytea
LANGUAGE plpgsql STABLE PARALLEL SAFE
AS $$
DECLARE
    camera record;
    current_sector doom._render_sector;
    far_sector doom._render_sector;
    eye_z double precision;
    forward_x double precision;
    forward_y double precision;
    focal double precision;
    center_y double precision;
    near_depth CONSTANT double precision := 0.001;
    column_x integer := -1;
    clip_top integer;
    clip_bottom integer;
    wall_top integer;
    wall_bottom integer;
    opening_top integer;
    opening_bottom integer;
    opening_floor integer;
    opening_ceiling integer;
    scale double precision;
    hit record;
    spans doom._render_span[] := ARRAY[]::doom._render_span[];
    actor_spans doom._render_span[] := ARRAY[]::doom._render_span[];
    row_patch record;
    rgb_row bytea;
    current_row_y integer := 0;
    frame_parts bytea[] := ARRAY[]::bytea[];
    frame bytea;
BEGIN
    IF p_width IS NULL OR p_height IS NULL
        OR p_width NOT BETWEEN 1 AND 4096 OR p_height NOT BETWEEN 1 AND 4096
        OR p_width::bigint * p_height > 1048576
    THEN
        RAISE EXCEPTION 'frame dimensions must be 1 to 4096 with at most 1048576 pixels'
            USING ERRCODE = '22023';
    END IF;

    SELECT game.level_id, actor.x, actor.y, actor.z, actor.angle,
           ROW(sector.sector_id,
               coalesce(state.floor_height, sector.floor_height),
               coalesce(state.ceiling_height, sector.ceiling_height),
               doom._render_rgb(sector.floor_color, sector.light_level),
               doom._render_rgb(sector.ceiling_color, sector.light_level))::doom._render_sector AS camera_sector
    INTO camera
    FROM doom.games AS game
    JOIN doom.actors AS actor ON actor.game_id = game.game_id AND actor.kind = 'player'
    JOIN doom.sectors AS sector ON sector.level_id = game.level_id AND sector.sector_id = actor.sector_id
    LEFT JOIN doom.sector_state AS state ON state.game_id = game.game_id AND state.sector_id = sector.sector_id
    WHERE game.game_id = p_game_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'game % has no player camera', p_game_id USING ERRCODE = 'P0002';
    END IF;

    eye_z := camera.z + 41;
    forward_x := cos(camera.angle);
    forward_y := sin(camera.angle);
    focal := p_width * 0.5;
    center_y := p_height * 0.5;

    FOR hit IN
        WITH surfaces AS MATERIALIZED (
            SELECT sector.sector_id, sector.light_level,
                   ROW(sector.sector_id,
                       coalesce(state.floor_height, sector.floor_height),
                       coalesce(state.ceiling_height, sector.ceiling_height),
                       doom._render_rgb(sector.floor_color, sector.light_level),
                       doom._render_rgb(sector.ceiling_color, sector.light_level))::doom._render_sector AS shape
            FROM doom.sectors AS sector
            LEFT JOIN doom.sector_state AS state
                ON state.game_id = p_game_id AND state.sector_id = sector.sector_id
            WHERE sector.level_id = camera.level_id
        ), view_lines AS MATERIALIZED (
            SELECT line.line_id, line.front_sector_id, line.back_sector_id, line.wall_color,
                   (line.x1 - camera.x) * forward_x + (line.y1 - camera.y) * forward_y AS a_depth,
                   (line.x2 - camera.x) * forward_x + (line.y2 - camera.y) * forward_y AS b_depth,
                   (line.x1 - camera.x) * forward_y - (line.y1 - camera.y) * forward_x AS a_right,
                   (line.x2 - camera.x) * forward_y - (line.y2 - camera.y) * forward_x AS b_right
            FROM doom.lines AS line
            WHERE line.level_id = camera.level_id
              AND line.front_sector_id IS DISTINCT FROM line.back_sector_id
        ), projected_lines AS MATERIALIZED (
            SELECT line.line_id, line.a_depth, line.a_right,
                   near.sector_id AS near_id, far.shape AS far_surface,
                   doom._render_rgb(line.wall_color, near.light_level) AS rgb,
                   geometry.numerator, line.b_depth - line.a_depth AS delta_depth,
                   line.b_right - line.a_right AS delta_right,
                   CASE WHEN line.a_depth >= near_depth THEN line.a_right / line.a_depth
                        ELSE (line.a_right + (line.b_right - line.a_right)
                            * (near_depth - line.a_depth) / (line.b_depth - line.a_depth)) / near_depth
                   END AS a_slope,
                   CASE WHEN line.b_depth >= near_depth THEN line.b_right / line.b_depth
                        ELSE (line.b_right + (line.a_right - line.b_right)
                            * (near_depth - line.b_depth) / (line.a_depth - line.b_depth)) / near_depth
                   END AS b_slope
            FROM view_lines AS line
            CROSS JOIN LATERAL (SELECT line.a_depth * line.b_right - line.a_right * line.b_depth AS numerator) AS geometry
            -- At a positive-depth hit the numerator and the ray determinant have the
            -- same sign. Choose and shade the side of each line once, before expanding it.
            JOIN surfaces AS near ON near.sector_id =
                CASE WHEN geometry.numerator > 0 THEN line.front_sector_id ELSE line.back_sector_id END
            LEFT JOIN surfaces AS far ON far.sector_id =
                CASE WHEN geometry.numerator > 0 THEN line.back_sector_id ELSE line.front_sector_id END
            WHERE greatest(line.a_depth, line.b_depth) >= near_depth AND geometry.numerator <> 0
        ), intersections AS (
            -- Only scan pixel centers between the near-clipped endpoints. A ray is
            -- (1, slope) in camera space, so its intersection t is already camera depth.
            SELECT pixel.x AS column_x, sample.depth, line.line_id, line.rgb, line.near_id, line.far_surface
            FROM projected_lines AS line
            CROSS JOIN LATERAL generate_series(
                least(p_width, greatest(0, ceil(focal * (1 + least(line.a_slope, line.b_slope)) - 0.500000001)))::integer,
                greatest(-1, least(p_width - 1, floor(focal * (1 + greatest(line.a_slope, line.b_slope)) - 0.499999999)))::integer
            ) AS pixel(x)
            CROSS JOIN LATERAL (SELECT (pixel.x + 0.5 - focal) / focal AS slope) AS ray_angle
            CROSS JOIN LATERAL (SELECT
                line.delta_right - ray_angle.slope * line.delta_depth AS determinant
            ) AS ray
            CROSS JOIN LATERAL (SELECT
                line.numerator / nullif(ray.determinant, 0) AS depth,
                (line.a_depth * ray_angle.slope - line.a_right) / nullif(ray.determinant, 0) AS along_line
            ) AS sample
            WHERE sample.depth >= near_depth
              AND sample.along_line BETWEEN -0.000000001 AND 1.000000001
        ), view_actors AS (
            SELECT actor.actor_id, actor.sector_id, actor.z, kind.radius, kind.color,
                   (actor.x - camera.x) * forward_x + (actor.y - camera.y) * forward_y AS depth,
                   (actor.x - camera.x) * forward_y - (actor.y - camera.y) * forward_x AS sideways,
                   CASE WHEN actor.life_state = 'dead' THEN kind.height * 0.2 ELSE kind.height END AS height,
                   CASE WHEN actor.life_state = 'dead' THEN surface.light_level * 2 / 3
                        ELSE surface.light_level END AS light
            FROM doom.actors AS actor
            JOIN doom.actor_types AS kind ON kind.kind = actor.kind
            JOIN surfaces AS surface ON surface.sector_id = actor.sector_id
            WHERE actor.game_id = p_game_id AND actor.kind <> 'player' AND kind.radius > 0
        ), visible_actors AS MATERIALIZED (
            SELECT actor.*, doom._render_rgb(actor.color, actor.light) AS rgb
            FROM view_actors AS actor
            WHERE actor.depth >= near_depth
        ), actor_slices AS (
            SELECT pixel.x AS column_x, actor.depth, actor.actor_id, actor.sector_id,
                   actor.rgb,
                   actor.z + actor.height * 0.5 * (1 - ellipse.extent) AS low_z,
                   actor.z + actor.height * 0.5 * (1 + ellipse.extent) AS high_z
            FROM visible_actors AS actor
            CROSS JOIN LATERAL generate_series(
                least(p_width, greatest(0, ceil(focal * (1 + (actor.sideways - actor.radius) / actor.depth) - 0.5)))::integer,
                greatest(-1, least(p_width - 1, floor(focal * (1 + (actor.sideways + actor.radius) / actor.depth) - 0.5)))::integer
            ) AS pixel(x)
            CROSS JOIN LATERAL (SELECT
                ((pixel.x + 0.5 - focal) * actor.depth / focal - actor.sideways) / actor.radius AS across
            ) AS sample
            CROSS JOIN LATERAL (SELECT sqrt(greatest(0, 1 - sample.across * sample.across)) AS extent) AS ellipse
        )
        SELECT i.column_x, i.depth, i.line_id::bigint AS hit_id, i.near_id, i.far_surface, i.rgb,
               false AS is_actor, NULL::double precision AS low_z, NULL::double precision AS high_z
        FROM intersections AS i
        UNION ALL
        SELECT sprite.column_x, sprite.depth, sprite.actor_id, sprite.sector_id,
               NULL, sprite.rgb, true, sprite.low_z, sprite.high_z
        FROM actor_slices AS sprite
        UNION ALL
        SELECT pixel.x, NULL, NULL, NULL, NULL, NULL, false, NULL, NULL
        FROM generate_series(0, p_width - 1) AS pixel(x)
        ORDER BY column_x, depth NULLS LAST, is_actor, hit_id
    LOOP
        IF hit.column_x <> column_x THEN
            column_x := hit.column_x;
            current_sector := camera.camera_sector;
            clip_top := 0;
            clip_bottom := p_height;
        END IF;

        IF clip_top >= clip_bottom THEN
            CONTINUE;
        END IF;

        IF hit.hit_id IS NULL THEN
            -- The remaining part of an open ray sees the current sector's planes.
            wall_top := greatest(clip_top, least(clip_bottom, ceil(center_y - 0.5)))::integer;
            spans := array_append(spans, ROW(column_x, clip_top, wall_top, current_sector.ceiling_rgb)::doom._render_span);
            spans := array_append(spans, ROW(column_x, wall_top, clip_bottom, current_sector.floor_rgb)::doom._render_span);
            CONTINUE;
        END IF;

        IF hit.near_id <> current_sector.sector_id THEN
            CONTINUE;
        END IF;

        scale := focal / hit.depth;
        IF hit.is_actor THEN
            -- Previous portal openings form a depth-correct clip for this sprite.
            wall_top := greatest(clip_top, least(clip_bottom, ceil(center_y
                + (eye_z - least(hit.high_z, current_sector.ceiling_height)) * scale - 0.5)))::integer;
            wall_bottom := greatest(clip_top, least(clip_bottom, ceil(center_y
                + (eye_z - greatest(hit.low_z, current_sector.floor_height)) * scale - 0.5)))::integer;
            IF wall_top < wall_bottom THEN
                actor_spans := array_append(actor_spans, ROW(column_x, wall_top, wall_bottom, hit.rgb)::doom._render_span);
            END IF;
            CONTINUE;
        END IF;

        wall_top := greatest(clip_top, least(clip_bottom,
            ceil(center_y + (eye_z - current_sector.ceiling_height) * scale - 0.5)))::integer;
        wall_bottom := greatest(clip_top, least(clip_bottom,
            ceil(center_y + (eye_z - current_sector.floor_height) * scale - 0.5)))::integer;

        spans := array_append(spans, ROW(column_x, clip_top, wall_top, current_sector.ceiling_rgb)::doom._render_span);
        spans := array_append(spans, ROW(column_x, wall_bottom, clip_bottom, current_sector.floor_rgb)::doom._render_span);

        far_sector := hit.far_surface;
        opening_floor := greatest(current_sector.floor_height, far_sector.floor_height);
        opening_ceiling := least(current_sector.ceiling_height, far_sector.ceiling_height);
        IF far_sector.sector_id IS NULL OR opening_floor >= opening_ceiling THEN
            spans := array_append(spans, ROW(column_x, wall_top, wall_bottom, hit.rgb)::doom._render_span);
            clip_top := clip_bottom;
            CONTINUE;
        END IF;

        opening_top := greatest(wall_top, least(wall_bottom,
            ceil(center_y + (eye_z - opening_ceiling) * scale - 0.5)))::integer;
        opening_bottom := greatest(wall_top, least(wall_bottom,
            ceil(center_y + (eye_z - opening_floor) * scale - 0.5)))::integer;
        spans := array_append(spans, ROW(column_x, wall_top, opening_top, hit.rgb)::doom._render_span);
        spans := array_append(spans, ROW(column_x, opening_bottom, wall_bottom, hit.rgb)::doom._render_span);
        clip_top := opening_top;
        clip_bottom := opening_bottom;
        current_sector := far_sector;
    END LOOP;

    IF cardinality(actor_spans) > 0 THEN
        spans := doom._render_layer_actors(spans, actor_spans);
    END IF;

    -- A span changes one column's color starting at row_start. Apply those changes
    -- to a single RGB row and reuse it for as many scanlines as stay identical.
    rgb_row := decode(repeat('00', 3 * p_width), 'hex');
    FOR row_patch IN
        SELECT span.row_start, span.column_x, span.rgb
        FROM unnest(spans) AS span
        WHERE span.row_start < span.row_end
        ORDER BY span.row_start, span.column_x
    LOOP
        IF row_patch.row_start > current_row_y THEN
            frame_parts := array_append(frame_parts, decode(repeat(encode(rgb_row, 'hex'),
                row_patch.row_start - current_row_y), 'hex'));
            current_row_y := row_patch.row_start;
        END IF;
        rgb_row := overlay(rgb_row PLACING row_patch.rgb FROM row_patch.column_x * 3 + 1 FOR 3);
    END LOOP;

    frame_parts := array_append(frame_parts, decode(repeat(encode(rgb_row, 'hex'), p_height - current_row_y), 'hex'));
    SELECT string_agg(part.data, ''::bytea ORDER BY part.n)
    INTO frame
    FROM unnest(frame_parts) WITH ORDINALITY AS part(data, n);

    RETURN frame;
END;
$$;
