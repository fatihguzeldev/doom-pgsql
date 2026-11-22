CREATE TYPE doom._render_sector AS (
    sector_id integer,
    floor_height integer,
    ceiling_height integer,
    floor_rgb bytea,
    ceiling_rgb bytea,
    light_level integer,
    floor_material text,
    ceiling_material text
);

CREATE FUNCTION doom._render_rgb(p_color integer, p_light integer)
RETURNS bytea
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
RETURN decode(lpad(to_hex(
    (((((p_color >> 16) & 255) * p_light + 127) / 255) << 16)
    | (((((p_color >> 8) & 255) * p_light + 127) / 255) << 8)
    | (((p_color & 255) * p_light + 127) / 255)
), 6, '0'), 'hex');

-- Opaque overlay spans arrive front to back. Subtract nearer spans before
-- sampling textures or unpacking the final RGB rows.
CREATE FUNCTION doom._render_layer_overlays(p_world doom._render_span[], p_overlays doom._render_span[])
RETURNS doom._render_span[]
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
RETURN (
    WITH overlay_rows AS MATERIALIZED (
        SELECT column_x, rgb, mapping, depth_order, int4range(row_start, row_end) AS rows
        FROM unnest(p_overlays) WITH ORDINALITY AS layer(column_x, row_start, row_end, rgb, mapping, depth_order)
    ), covered_rows AS (
        SELECT column_x, range_agg(rows) AS mask
        FROM overlay_rows
        GROUP BY column_x
    ), overlay_masks AS (
        SELECT column_x, rows, rgb, mapping,
               range_agg(rows) OVER (PARTITION BY column_x ORDER BY depth_order
                   ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS mask
        FROM overlay_rows
    ), pieces AS (
        SELECT layer.column_x, visible.rows, layer.rgb, layer.mapping
        FROM overlay_masks AS layer
        CROSS JOIN LATERAL unnest(int4multirange(layer.rows)
            - coalesce(layer.mask, '{}'::int4multirange)) AS visible(rows)
        UNION ALL
        SELECT base.column_x, visible.rows, base.rgb, base.mapping
        FROM unnest(p_world) AS base
        LEFT JOIN covered_rows AS covered ON covered.column_x = base.column_x
        CROSS JOIN LATERAL unnest(int4multirange(int4range(base.row_start, base.row_end))
            - coalesce(covered.mask, '{}'::int4multirange)) AS visible(rows)
    )
    SELECT array_agg(ROW(column_x, lower(rows), upper(rows), rgb, mapping)::doom._render_span)
    FROM pieces
);

-- All frame encodings consume the same composited spans from one snapshot.
-- Estimated texture sampling cost can trigger LLVM compilation for a small frame.
CREATE FUNCTION doom._render_frame(
    p_game_id bigint, p_width integer, p_height integer, p_span_packet boolean, p_compact boolean,
    p_column_major boolean, p_first_column integer, p_column_count integer
)
RETURNS bytea
LANGUAGE plpgsql STABLE PARALLEL SAFE
SET jit = off
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
    has_materials boolean;
    ray_slope double precision;
    plane_ray_x double precision;
    plane_ray_y double precision;
    wall_surface doom.line_surfaces;
    wall_v double precision;
    wall_dv double precision;
    near_depth CONSTANT double precision := 0.001;
    pixel_epsilon CONSTANT double precision := 0.000000001;
    last_column integer;
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
    overlays doom._render_span[] := ARRAY[]::doom._render_span[];
    has_mask_candidates boolean := false;
    row_patch record;
    has_mapped_spans boolean;
    change_count bigint;
    rgb_size bigint;
    format_tag bytea;
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
    IF p_first_column IS NULL OR p_column_count IS NULL OR p_first_column < 0 OR p_column_count < 1
        OR p_first_column::bigint + p_column_count > p_width
    THEN
        RAISE EXCEPTION 'column window must be nonempty and within the frame width'
            USING ERRCODE = '22023';
    END IF;
    last_column := p_first_column + p_column_count - 1;

    SELECT game.level_id, game.tick_number, actor.x, actor.y, actor.z, actor.angle,
           EXISTS (SELECT FROM doom.level_palettes AS palette WHERE palette.level_id = game.level_id)
               AND EXISTS (SELECT FROM doom.level_materials AS material WHERE material.level_id = game.level_id)
               AS has_materials,
           ROW(sector.sector_id,
               coalesce(state.floor_height, sector.floor_height),
               coalesce(state.ceiling_height, sector.ceiling_height),
               doom._render_rgb(sector.floor_color, sector.light_level),
               doom._render_rgb(sector.ceiling_color, sector.light_level),
               sector.light_level, sector.floor_material, sector.ceiling_material)::doom._render_sector AS camera_sector
    INTO camera
    FROM doom.games AS game
    JOIN doom.actors AS actor ON actor.game_id = game.game_id AND actor.kind = 'player'
    JOIN doom.sectors AS sector ON sector.level_id = game.level_id AND sector.sector_id = actor.sector_id
    LEFT JOIN doom.sector_state AS state ON state.game_id = game.game_id AND state.sector_id = sector.sector_id
    WHERE game.game_id = p_game_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'game % has no player camera', p_game_id USING ERRCODE = 'P0002';
    END IF;

    eye_z := doom._eye_z(camera.z);
    forward_x := cos(camera.angle);
    forward_y := sin(camera.angle);
    focal := p_width * 0.5;
    center_y := p_height * 0.5;
    has_materials := camera.has_materials;

    FOR hit IN
        WITH RECURSIVE surfaces AS MATERIALIZED (
            SELECT sector.sector_id, sector.light_level,
                   ROW(sector.sector_id,
                       coalesce(state.floor_height, sector.floor_height),
                       coalesce(state.ceiling_height, sector.ceiling_height),
                       doom._render_rgb(sector.floor_color, sector.light_level),
                       doom._render_rgb(sector.ceiling_color, sector.light_level),
                       sector.light_level, sector.floor_material, sector.ceiling_material)::doom._render_sector AS shape
            FROM doom.sectors AS sector
            LEFT JOIN doom.sector_state AS state
                ON state.game_id = p_game_id AND state.sector_id = sector.sector_id
            WHERE sector.level_id = camera.level_id
        ), camera_lines AS MATERIALIZED (
            SELECT line.*, far.sector_id IS NOT NULL
                       AND greatest((camera.camera_sector).floor_height, (far.shape).floor_height)
                           < least((camera.camera_sector).ceiling_height, (far.shape).ceiling_height) AS has_opening
            FROM doom._project_render_lines(camera.level_id, (camera.camera_sector).sector_id, true, has_materials,
                camera.x, camera.y, forward_x, forward_y, focal, p_width, p_first_column, last_column,
                near_depth, pixel_epsilon) AS line
            LEFT JOIN surfaces AS far ON far.sector_id = line.far_id
        ), camera_crossings AS MATERIALIZED (
            -- A ray is (1, slope) in camera space, so its intersection distance
            -- is already camera depth. Use the leftward depth derivative to sort
            -- simultaneous crossings at the same projected vertex.
            SELECT pixel.x AS column_x, line.line_id,
                   CASE WHEN pixel.x = line.vertex_col THEN line.vertex_depth ELSE sample.depth END AS depth,
                   CASE WHEN pixel.x = line.vertex_col THEN line.vertex_slope ELSE 0 END AS depth_slope,
                   ray_angle.slope, ray.determinant, line.far_id AS far_sector_id, line.has_opening
            FROM camera_lines AS line
            CROSS JOIN LATERAL generate_series(
                greatest(p_first_column, line.first_col), least(last_column, line.last_col)
            ) AS pixel(x)
            CROSS JOIN LATERAL (SELECT (pixel.x + 0.5 - focal) / focal AS slope) AS ray_angle
            CROSS JOIN LATERAL (SELECT
                line.delta_right - ray_angle.slope * line.delta_depth AS determinant
            ) AS ray
            CROSS JOIN LATERAL (SELECT line.numerator / nullif(ray.determinant, 0) AS depth) AS sample
            WHERE sample.depth >= near_depth
        ), first_hits AS MATERIALIZED (
            SELECT DISTINCT ON (crossing.column_x) crossing.column_x, crossing.line_id, crossing.depth,
                   crossing.far_sector_id, crossing.has_opening
            FROM camera_crossings AS crossing
            ORDER BY crossing.column_x, crossing.depth, crossing.depth_slope, crossing.line_id
        ), openings AS MATERIALIZED (
            SELECT first_hit.far_sector_id,
                   range_agg(int4range(first_hit.column_x, first_hit.column_x + 1)) AS ranges
            FROM first_hits AS first_hit
            WHERE first_hit.has_opening
            GROUP BY first_hit.far_sector_id
        ), distant_lines AS MATERIALIZED (
            SELECT line.*, far.sector_id IS NOT NULL
                       AND greatest((near.shape).floor_height, (far.shape).floor_height)
                           < least((near.shape).ceiling_height, (far.shape).ceiling_height) AS has_opening
            FROM doom._project_render_lines(camera.level_id, (camera.camera_sector).sector_id, false, has_materials,
                camera.x, camera.y, forward_x, forward_y, focal, p_width, p_first_column, last_column,
                near_depth, pixel_epsilon) AS line
            JOIN surfaces AS near ON near.sector_id = line.near_id
            LEFT JOIN surfaces AS far ON far.sector_id = line.far_id
            WHERE EXISTS (SELECT 1 FROM openings)
        ), portal_windows AS MATERIALIZED (
            SELECT line.near_id, line.far_id, int4range(line.first_col, line.last_col + 1) AS columns
            FROM camera_lines AS line
            WHERE line.has_opening
            UNION ALL
            SELECT line.near_id, line.far_id, int4range(line.first_col, line.last_col + 1)
            FROM distant_lines AS line
            WHERE line.has_opening
        ), reached(hop, sector_id, columns) AS (
            SELECT 1, opening.far_sector_id, span.columns
            FROM openings AS opening
            CROSS JOIN LATERAL unnest(opening.ranges) AS span(columns)
            UNION
            SELECT previous.hop + 1, portal.far_id, previous.columns * portal.columns
            FROM reached AS previous
            JOIN portal_windows AS portal ON portal.near_id = previous.sector_id
                AND portal.columns && previous.columns
            WHERE previous.hop < 3
        ), sector_windows AS MATERIALIZED (
            -- No depth or height sorting is needed to form a conservative candidate.
            -- Overlap can admit extra lines, but never hides a reachable sector.
            SELECT reachable.sector_id, range_agg(reachable.columns) AS ranges
            FROM reached AS reachable
            WHERE reachable.hop < 3
            GROUP BY reachable.sector_id
        ), farther_windows AS MATERIALIZED (
            -- For deep portal chains, rejoin the exact crossing search on those columns.
            SELECT coalesce(range_agg(reachable.columns), '{}'::int4multirange) AS ranges
            FROM reached AS reachable
            WHERE reachable.hop = 3
        ), closed_columns AS MATERIALIZED (
            SELECT first_hit.column_x, first_hit.line_id, first_hit.depth
            FROM first_hits AS first_hit
            WHERE NOT first_hit.has_opening
        ), crossings AS (
            SELECT crossing.column_x, crossing.line_id, crossing.depth, crossing.depth_slope,
                   crossing.slope, crossing.determinant
            FROM camera_crossings AS crossing
            LEFT JOIN closed_columns AS closed USING (column_x)
            WHERE closed.line_id IS NULL OR closed.line_id = crossing.line_id
            UNION ALL
            SELECT pixel.x, line.line_id,
                   CASE WHEN pixel.x = line.vertex_col THEN line.vertex_depth ELSE sample.depth END,
                   CASE WHEN pixel.x = line.vertex_col THEN line.vertex_slope ELSE 0 END,
                   ray_angle.slope, ray.determinant
            FROM distant_lines AS line
            LEFT JOIN sector_windows AS sector_open ON sector_open.sector_id = line.near_id
            CROSS JOIN farther_windows AS farther
            CROSS JOIN LATERAL unnest((coalesce(sector_open.ranges, '{}'::int4multirange) + farther.ranges)
                * int4multirange(int4range(line.first_col, line.last_col + 1))) AS visible(columns)
            CROSS JOIN LATERAL generate_series(lower(visible.columns), upper(visible.columns) - 1) AS pixel(x)
            CROSS JOIN LATERAL (SELECT (pixel.x + 0.5 - focal) / focal AS slope) AS ray_angle
            CROSS JOIN LATERAL (SELECT
                line.delta_right - ray_angle.slope * line.delta_depth AS determinant
            ) AS ray
            CROSS JOIN LATERAL (SELECT line.numerator / nullif(ray.determinant, 0) AS depth) AS sample
            WHERE sample.depth >= near_depth
        ), line_appearance AS MATERIALIZED (
            SELECT line.*, doom._render_rgb(line.wall_color, near.light_level) AS rgb, far.shape AS far_surface,
                   face AS wall_surface,
                   CASE WHEN face.upper_material IS NOT NULL OR face.lower_material IS NOT NULL
                          OR face.middle_material IS NOT NULL
                        THEN sqrt(line.delta_depth ^ 2 + line.delta_right ^ 2)
                   END AS wall_length
            FROM (SELECT * FROM camera_lines UNION ALL SELECT * FROM distant_lines) AS line
            JOIN surfaces AS near ON near.sector_id = line.near_id
            LEFT JOIN surfaces AS far ON far.sector_id = line.far_id
            LEFT JOIN doom.line_surfaces AS face ON has_materials AND face.level_id = camera.level_id
                AND face.line_id = line.line_id AND face.is_back = line.is_back
        ), intersections AS (
            SELECT crossing.column_x, line.line_id, line.rgb, line.near_id, line.far_surface,
                   crossing.depth, crossing.depth_slope, line.wall_surface,
                   CASE WHEN line.wall_length IS NOT NULL THEN (line.wall_surface).x_offset + line.wall_length *
                        CASE WHEN (line.wall_surface).is_back THEN 1 - along.fraction ELSE along.fraction END
                   END AS wall_u
            FROM crossings AS crossing
            JOIN line_appearance AS line USING (line_id)
            CROSS JOIN LATERAL (SELECT greatest(0, least(1,
                (crossing.slope * line.a_depth - line.a_right) / nullif(crossing.determinant, 0)
            )) AS fraction) AS along
        ), view_actors AS (
            SELECT actor.actor_id, actor.sector_id, actor.z, kind.radius, kind.color,
                   (actor.x - camera.x) * forward_x + (actor.y - camera.y) * forward_y AS depth,
                   (actor.x - camera.x) * forward_y - (actor.y - camera.y) * forward_x AS sideways,
                   sprite.name AS sprite_name, sprite.width AS sprite_width, sprite.height AS sprite_height,
                   sprite.left_offset, sprite.top_offset,
                   CASE WHEN actor.life_state = 'dead' THEN kind.height * 0.2 ELSE kind.height END AS height,
                   CASE WHEN actor.life_state = 'dead' AND sprite.name IS NULL THEN surface.light_level * 2 / 3
                        ELSE surface.light_level END AS light
            FROM doom.actors AS actor
            JOIN doom.actor_types AS kind ON kind.kind = actor.kind
            JOIN surfaces AS surface ON surface.sector_id = actor.sector_id
            CROSS JOIN LATERAL (SELECT
                CASE WHEN actor.life_state = 'dead' THEN kind.dead_sprite_frames ELSE kind.sprite_frames END AS frames,
                CASE WHEN actor.life_state = 'dead' THEN kind.dead_sprite_frame_ticks
                     ELSE kind.sprite_frame_ticks END AS frame_ticks,
                CASE WHEN actor.life_state = 'dead' THEN kind.dead_sprite_material ELSE kind.sprite_material END AS static_name
            ) AS clip
            CROSS JOIN LATERAL (SELECT cardinality(clip.frames) AS frame_count,
                greatest(0, camera.tick_number - actor.animation_start_tick) / clip.frame_ticks AS elapsed_frames
            ) AS phase
            CROSS JOIN LATERAL (SELECT CASE WHEN has_materials AND phase.frame_count > 0
                THEN clip.frames[array_lower(clip.frames, 1) +
                    (CASE WHEN actor.life_state = 'dead' THEN least(phase.elapsed_frames, phase.frame_count - 1)
                          ELSE phase.elapsed_frames % phase.frame_count END)::integer]
                END AS animated_name
            ) AS selected
            -- Keep the availability guards inside each lookup even with a generic plan.
            LEFT JOIN LATERAL (
                SELECT name, width, height, left_offset, top_offset FROM doom.level_materials
                WHERE has_materials AND selected.animated_name IS NOT NULL
                    AND level_id = camera.level_id AND surface_kind = 'sprite'
                    AND name = upper(selected.animated_name COLLATE "C") COLLATE "default"
                LIMIT 1
            ) AS animated ON true
            LEFT JOIN LATERAL (
                SELECT name, width, height, left_offset, top_offset FROM doom.level_materials
                WHERE has_materials AND animated.name IS NULL AND clip.static_name IS NOT NULL
                    AND level_id = camera.level_id AND surface_kind = 'sprite'
                    AND name = upper(clip.static_name COLLATE "C") COLLATE "default"
                LIMIT 1
            ) AS still ON true
            CROSS JOIN LATERAL (SELECT coalesce(animated.name, still.name) AS name,
                coalesce(animated.width, still.width) AS width, coalesce(animated.height, still.height) AS height,
                coalesce(animated.left_offset, still.left_offset) AS left_offset,
                coalesce(animated.top_offset, still.top_offset) AS top_offset
            ) AS sprite
            WHERE actor.game_id = p_game_id AND actor.kind <> 'player'
                AND (actor.sector_id = (camera.camera_sector).sector_id
                     OR EXISTS (SELECT FROM sector_windows AS visible WHERE visible.sector_id = actor.sector_id)
                     OR EXISTS (SELECT FROM farther_windows AS visible WHERE NOT isempty(visible.ranges)))
                AND (kind.radius > 0 OR sprite.name IS NOT NULL)
        ), visible_actors AS MATERIALIZED (
            SELECT actor.*, doom._render_rgb(actor.color, actor.light) AS rgb,
                   CASE WHEN actor.sprite_name IS NULL THEN actor.sideways - actor.radius
                        ELSE actor.sideways - actor.left_offset END AS left_edge,
                   CASE WHEN actor.sprite_name IS NULL THEN actor.sideways + actor.radius
                        ELSE actor.sideways - actor.left_offset + actor.sprite_width END AS right_edge
            FROM view_actors AS actor
            WHERE actor.depth >= near_depth
        ), actor_slices AS (
            SELECT pixel.x AS column_x, actor.depth, actor.actor_id, actor.sector_id,
                   actor.rgb,
                   CASE WHEN actor.sprite_name IS NULL THEN actor.z + actor.height * 0.5 * (1 - ellipse.extent)
                        ELSE actor.z + actor.top_offset - actor.sprite_height END AS low_z,
                   CASE WHEN actor.sprite_name IS NULL THEN actor.z + actor.height * 0.5 * (1 + ellipse.extent)
                        ELSE actor.z + actor.top_offset END AS high_z,
                   CASE WHEN actor.sprite_name IS NOT NULL THEN ROW('sprite', actor.sprite_name, actor.light,
                        sample.view_x - actor.left_edge,
                        actor.z + actor.top_offset - eye_z + (0.5 - center_y) * sample.dv,
                        0, sample.dv, false)::doom._render_mapping END AS mapping
            FROM visible_actors AS actor
            CROSS JOIN LATERAL (SELECT
                focal * (1 + actor.left_edge / actor.depth) - 0.5 AS left_x,
                focal * (1 + actor.right_edge / actor.depth) - 0.5 AS right_x
            ) AS edges
            CROSS JOIN LATERAL generate_series(
                least(p_width, greatest(p_first_column, ceil(edges.left_x)))::integer,
                greatest(-1, least(last_column, CASE WHEN actor.sprite_name IS NULL THEN floor(edges.right_x)
                    ELSE ceil(edges.right_x) - 1 END))::integer
            ) AS pixel(x)
            CROSS JOIN LATERAL (SELECT
                (pixel.x + 0.5 - focal) * actor.depth / focal AS view_x,
                actor.depth / focal AS dv
            ) AS sample
            CROSS JOIN LATERAL (SELECT CASE WHEN actor.sprite_name IS NULL
                THEN (sample.view_x - actor.sideways) / actor.radius END AS across) AS ellipse_sample
            CROSS JOIN LATERAL (SELECT sqrt(greatest(0, 1 - ellipse_sample.across * ellipse_sample.across)) AS extent) AS ellipse
            LEFT JOIN closed_columns AS closed ON closed.column_x = pixel.x
            LEFT JOIN sector_windows AS sector_open ON sector_open.sector_id = actor.sector_id
            CROSS JOIN farther_windows AS farther
            WHERE CASE WHEN actor.sector_id = (camera.camera_sector).sector_id
                THEN closed.column_x IS NULL OR actor.depth < closed.depth
                ELSE sector_open.ranges @> pixel.x OR farther.ranges @> pixel.x END
        )
        SELECT i.column_x, i.depth, i.line_id::bigint AS hit_id, i.near_id, i.far_surface, i.rgb,
               false AS is_actor, NULL::double precision AS low_z, NULL::double precision AS high_z,
               i.depth_slope, i.wall_surface, i.wall_u, NULL::doom._render_mapping AS actor_mapping
        FROM intersections AS i
        UNION ALL
        SELECT sprite.column_x, sprite.depth, sprite.actor_id, sprite.sector_id,
               NULL, sprite.rgb, true, sprite.low_z, sprite.high_z, 0,
               NULL::doom.line_surfaces, NULL::double precision, sprite.mapping
        FROM actor_slices AS sprite
        UNION ALL
        SELECT pixel.x, NULL, NULL, NULL, NULL, NULL, false, NULL, NULL, 0,
               NULL::doom.line_surfaces, NULL::double precision, NULL::doom._render_mapping
        FROM generate_series(p_first_column, last_column) AS pixel(x)
        ORDER BY column_x, depth NULLS LAST, is_actor, depth_slope, hit_id
    LOOP
        IF hit.column_x <> column_x THEN
            column_x := hit.column_x;
            current_sector := camera.camera_sector;
            clip_top := 0;
            clip_bottom := p_height;
            IF has_materials THEN
                ray_slope := (column_x + 0.5 - focal) / focal;
                plane_ray_x := (forward_x + ray_slope * forward_y) * focal;
                plane_ray_y := (forward_y - ray_slope * forward_x) * focal;
            END IF;
        END IF;

        IF clip_top >= clip_bottom THEN
            CONTINUE;
        END IF;

        IF hit.hit_id IS NULL THEN
            -- The remaining part of an open ray sees the current sector's planes.
            wall_top := greatest(clip_top, least(clip_bottom, ceil(center_y - 0.5)))::integer;
            wall_bottom := wall_top;
        ELSE
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
                    overlays := array_append(overlays,
                        ROW(column_x, wall_top, wall_bottom, hit.rgb, hit.actor_mapping)::doom._render_span);
                    IF hit.actor_mapping IS NOT NULL THEN
                        has_mask_candidates := true;
                    END IF;
                END IF;
                CONTINUE;
            END IF;

            wall_top := greatest(clip_top, least(clip_bottom,
                ceil(center_y + (eye_z - current_sector.ceiling_height) * scale - 0.5)))::integer;
            wall_bottom := greatest(clip_top, least(clip_bottom,
                ceil(center_y + (eye_z - current_sector.floor_height) * scale - 0.5)))::integer;
        END IF;

        IF clip_top < wall_top THEN
            spans := array_append(spans, ROW(column_x, clip_top, wall_top, current_sector.ceiling_rgb,
                CASE WHEN has_materials AND current_sector.ceiling_material IS NOT NULL
                          AND eye_z < current_sector.ceiling_height THEN
                    ROW('flat', current_sector.ceiling_material, current_sector.light_level, camera.x, camera.y,
                        (eye_z - current_sector.ceiling_height) * plane_ray_x,
                        (eye_z - current_sector.ceiling_height) * plane_ray_y, true)::doom._render_mapping
                END)::doom._render_span);
        END IF;
        IF wall_bottom < clip_bottom THEN
            spans := array_append(spans, ROW(column_x, wall_bottom, clip_bottom, current_sector.floor_rgb,
                CASE WHEN has_materials AND current_sector.floor_material IS NOT NULL
                          AND eye_z > current_sector.floor_height THEN
                    ROW('flat', current_sector.floor_material, current_sector.light_level, camera.x, camera.y,
                        (eye_z - current_sector.floor_height) * plane_ray_x,
                        (eye_z - current_sector.floor_height) * plane_ray_y, true)::doom._render_mapping
                END)::doom._render_span);
        END IF;

        IF hit.hit_id IS NULL THEN
            CONTINUE;
        END IF;

        IF has_materials THEN
            wall_surface := hit.wall_surface;
            IF hit.wall_u IS NOT NULL THEN
                wall_dv := hit.depth / focal;
                wall_v := wall_surface.y_offset - eye_z + (0.5 - center_y) * wall_dv;
            END IF;
        END IF;

        far_sector := hit.far_surface;
        opening_floor := greatest(current_sector.floor_height, far_sector.floor_height);
        opening_ceiling := least(current_sector.ceiling_height, far_sector.ceiling_height);
        IF far_sector.sector_id IS NULL OR (opening_floor >= opening_ceiling
            AND (NOT has_materials OR (wall_surface.upper_material IS NULL AND wall_surface.lower_material IS NULL)))
        THEN
            IF wall_top < wall_bottom THEN
                spans := array_append(spans, ROW(column_x, wall_top, wall_bottom, hit.rgb,
                    CASE WHEN has_materials AND wall_surface.middle_material IS NOT NULL THEN
                        ROW('wall', wall_surface.middle_material, current_sector.light_level,
                            hit.wall_u, wall_v + current_sector.ceiling_height, 0, wall_dv, false)::doom._render_mapping
                    END)::doom._render_span);
            END IF;
            clip_top := clip_bottom;
            CONTINUE;
        END IF;

        opening_top := greatest(wall_top, least(wall_bottom,
            ceil(center_y + (eye_z - opening_ceiling) * scale - 0.5)))::integer;
        opening_bottom := greatest(wall_top, least(wall_bottom,
            ceil(center_y + (eye_z - opening_floor) * scale - 0.5)))::integer;
        IF wall_top < opening_top THEN
            spans := array_append(spans, ROW(column_x, wall_top, opening_top, hit.rgb,
                CASE WHEN has_materials AND wall_surface.upper_material IS NOT NULL THEN
                    ROW('wall', wall_surface.upper_material, current_sector.light_level,
                        hit.wall_u, wall_v + current_sector.ceiling_height, 0, wall_dv, false)::doom._render_mapping
                END)::doom._render_span);
        END IF;
        IF opening_bottom < wall_bottom THEN
            spans := array_append(spans, ROW(column_x, opening_bottom, wall_bottom, hit.rgb,
                CASE WHEN has_materials AND wall_surface.lower_material IS NOT NULL THEN
                    ROW('wall', wall_surface.lower_material, current_sector.light_level,
                        hit.wall_u, wall_v + opening_floor, 0, wall_dv, false)::doom._render_mapping
                END)::doom._render_span);
        END IF;
        IF has_materials AND wall_surface.middle_material IS NOT NULL AND opening_top < opening_bottom THEN
            overlays := array_append(overlays, ROW(column_x, opening_top, opening_bottom, hit.rgb,
                ROW('wall', wall_surface.middle_material, current_sector.light_level,
                    hit.wall_u, wall_v + opening_ceiling, 0, wall_dv, false)::doom._render_mapping)::doom._render_span);
            has_mask_candidates := true;
        END IF;
        clip_top := opening_top;
        clip_bottom := opening_bottom;
        current_sector := far_sector;
    END LOOP;

    IF has_mask_candidates THEN
        overlays := doom._clip_masked_render_spans(camera.level_id, overlays);
    END IF;
    IF cardinality(overlays) > 0 THEN
        spans := doom._render_layer_overlays(spans, overlays);
    END IF;
    IF p_column_major THEN
        IF p_span_packet THEN
            RETURN doom._sample_render_blocks(camera.level_id, spans, center_y);
        END IF;
        RETURN doom._sample_render_frame(camera.level_id, spans, center_y, false, true);
    END IF;
    IF has_materials THEN
        SELECT bool_or((span.mapping).material_name IS NOT NULL),
               sum(CASE WHEN (span.mapping).material_name IS NOT NULL THEN span.row_end - span.row_start ELSE 1 END)
        INTO has_mapped_spans, change_count
        FROM unnest(spans) AS span;
    END IF;

    IF p_compact THEN
        rgb_size := 3 * p_width::bigint * p_height;
        p_span_packet := 7 * cardinality(spans)::bigint < rgb_size;
        -- Consult the material catalog only if the lower and upper counts choose different encodings.
        IF p_span_packet AND has_mapped_spans AND 7 * change_count >= rgb_size THEN
            p_span_packet := 7 * doom._render_change_count(camera.level_id, spans) < rgb_size;
        END IF;
        format_tag := CASE WHEN p_span_packet THEN '\x01'::bytea ELSE '\x00'::bytea END;
    END IF;

    IF has_mapped_spans THEN
        -- At higher change densities the scanline patches cost more than a direct RGB aggregate.
        IF p_span_packet OR change_count > p_width::bigint * p_height * 45 / 100 THEN
            frame := doom._sample_render_frame(camera.level_id, spans, center_y, p_span_packet);
            RETURN CASE WHEN p_compact THEN format_tag || frame ELSE frame END;
        END IF;

        -- Sample the textured pixels and reuse the solid spans as scanline changes.
        SELECT array_agg(ROW(sample.ordinal & 65535, sample.ordinal >> 16,
                             (sample.ordinal >> 16) + 1, sample.rgb, NULL)::doom._render_span)
        INTO spans
        FROM doom._sample_render_rows(camera.level_id, spans, center_y, true) AS sample;
    END IF;

    IF p_span_packet THEN
        SELECT string_agg(
            int2send(span.row_start::smallint) || int2send(span.column_x::smallint) || span.rgb,
            ''::bytea ORDER BY span.row_start, span.column_x
        )
        INTO frame
        FROM unnest(spans) AS span;
        RETURN CASE WHEN p_compact THEN format_tag || frame ELSE frame END;
    END IF;

    -- A span changes one column's color starting at row_start. Apply those changes
    -- to a single RGB row and reuse it for as many scanlines as stay identical.
    rgb_row := decode(repeat('00', 3 * p_width), 'hex');
    FOR row_patch IN
        SELECT span.row_start, span.column_x, span.rgb
        FROM unnest(spans) AS span
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

    RETURN CASE WHEN p_compact THEN format_tag || frame ELSE frame END;
END;
$$;

-- RGB888 pixels, left to right and top to bottom.
CREATE FUNCTION doom.render(p_game_id bigint, p_width integer, p_height integer)
RETURNS bytea
LANGUAGE sql STABLE PARALLEL SAFE
RETURN doom._render_frame(p_game_id, p_width, p_height, false, false, false, 0, p_width);

-- RGB888 pixels, top to bottom within each column, columns ordered left to right.
CREATE FUNCTION doom.render_columns(p_game_id bigint, p_width integer, p_height integer)
RETURNS bytea
LANGUAGE sql STABLE PARALLEL SAFE
RETURN doom._render_frame(p_game_id, p_width, p_height, false, false, true, 0, p_width);

-- Records contain uint16 column, start row, count, then count RGB888 colors, in network byte order.
CREATE FUNCTION doom.render_blocks(p_game_id bigint, p_width integer, p_height integer)
RETURNS bytea
LANGUAGE sql STABLE PARALLEL SAFE
RETURN doom._render_frame(p_game_id, p_width, p_height, true, false, true, 0, p_width);

-- A window of column-major RGB888 pixels from the full viewport, starting at a zero-based column.
CREATE FUNCTION doom.render_column_window(
    p_game_id bigint, p_width integer, p_height integer, p_first_column integer, p_column_count integer
)
RETURNS bytea
LANGUAGE sql STABLE PARALLEL SAFE
RETURN doom._render_frame(p_game_id, p_width, p_height, false, false, true, p_first_column, p_column_count);

-- Seven-byte row changes: row and column as big-endian uint16, then RGB888.
-- Row zero initializes every column. Later rows reuse colors until they change.
CREATE FUNCTION doom.render_spans(p_game_id bigint, p_width integer, p_height integer)
RETURNS bytea
LANGUAGE sql STABLE PARALLEL SAFE
RETURN doom._render_frame(p_game_id, p_width, p_height, true, false, false, 0, p_width);

-- A one-byte tag (0 for RGB888, 1 for spans) precedes the smaller body.
-- Equal body sizes use RGB888.
CREATE FUNCTION doom.render_compact(p_game_id bigint, p_width integer, p_height integer)
RETURNS bytea
LANGUAGE sql STABLE PARALLEL SAFE
RETURN doom._render_frame(p_game_id, p_width, p_height, false, true, false, 0, p_width);
