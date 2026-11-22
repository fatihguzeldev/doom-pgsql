-- Project only the camera's boundary before deciding whether to visit other sectors.
-- The final wall and sprite compositor still owns depth, material and vertical clipping.
CREATE FUNCTION doom._project_render_lines(
    p_level_id bigint, p_camera_sector integer, p_camera_only boolean, p_has_materials boolean,
    p_x double precision, p_y double precision, p_forward_x double precision, p_forward_y double precision,
    p_focal double precision, p_width integer, p_first_column integer, p_last_column integer,
    p_near_depth double precision, p_epsilon double precision
)
RETURNS TABLE(
    line_id integer, near_id integer, far_id integer, wall_color integer, is_back boolean,
    a_depth double precision, a_right double precision, numerator double precision,
    delta_depth double precision, delta_right double precision,
    first_col integer, last_col integer, vertex_col integer,
    vertex_depth double precision, vertex_slope double precision
)
LANGUAGE sql STABLE PARALLEL SAFE
AS $$
    WITH compiled AS MATERIALIZED (
        SELECT sector.line_ids
        FROM doom.wad_sector_lines AS sector
        WHERE p_camera_only AND sector.level_id = p_level_id AND sector.sector_id = p_camera_sector
    ), lines AS (
        SELECT line.*
        FROM compiled AS sector
        CROSS JOIN LATERAL unnest(sector.line_ids) AS member(line_id)
        JOIN doom.lines AS line ON line.level_id = p_level_id AND line.line_id = member.line_id
        UNION ALL
        SELECT line.*
        FROM doom.lines AS line
        WHERE line.level_id = p_level_id AND p_camera_only AND line.front_sector_id = p_camera_sector
            AND NOT EXISTS (SELECT FROM compiled)
        UNION ALL
        SELECT line.*
        FROM doom.lines AS line
        WHERE line.level_id = p_level_id AND p_camera_only AND line.back_sector_id = p_camera_sector
            AND line.front_sector_id <> p_camera_sector
            AND NOT EXISTS (SELECT FROM compiled)
        UNION ALL
        SELECT line.*
        FROM doom.lines AS line
        WHERE line.level_id = p_level_id AND NOT p_camera_only
    ), camera_space AS MATERIALIZED (
        SELECT line.line_id, line.front_sector_id, line.back_sector_id, line.wall_color,
               (line.x1 - p_x) * p_forward_x + (line.y1 - p_y) * p_forward_y AS a_depth,
               (line.x2 - p_x) * p_forward_x + (line.y2 - p_y) * p_forward_y AS b_depth,
               (line.x1 - p_x) * p_forward_y - (line.y1 - p_y) * p_forward_x AS a_right,
               (line.x2 - p_x) * p_forward_y - (line.y2 - p_y) * p_forward_x AS b_right
        FROM lines AS line
        WHERE p_has_materials OR line.front_sector_id IS DISTINCT FROM line.back_sector_id
    ), projected AS MATERIALIZED (
        SELECT line.line_id, side.near_id, side.far_id, line.wall_color, geometry.numerator < 0 AS is_back,
               line.a_depth, line.a_right, geometry.numerator,
               line.b_depth - line.a_depth AS delta_depth,
               line.b_right - line.a_right AS delta_right,
               greatest(p_near_depth,
                   CASE WHEN geometry.numerator > 0 THEN line.b_depth ELSE line.a_depth END) AS vertex_depth,
               CASE WHEN line.a_depth >= p_near_depth THEN line.a_right / line.a_depth
                    ELSE (line.a_right + (line.b_right - line.a_right)
                        * (p_near_depth - line.a_depth) / (line.b_depth - line.a_depth)) / p_near_depth
               END AS a_slope,
               CASE WHEN line.b_depth >= p_near_depth THEN line.b_right / line.b_depth
                    ELSE (line.b_right + (line.a_right - line.b_right)
                        * (p_near_depth - line.b_depth) / (line.a_depth - line.b_depth)) / p_near_depth
               END AS b_slope
        FROM camera_space AS line
        CROSS JOIN LATERAL (
            SELECT line.a_depth * line.b_right - line.a_right * line.b_depth AS numerator
        ) AS geometry
        CROSS JOIN LATERAL (
            SELECT CASE WHEN geometry.numerator > 0 THEN line.front_sector_id ELSE line.back_sector_id END AS near_id,
                   CASE WHEN geometry.numerator > 0 THEN line.back_sector_id ELSE line.front_sector_id END AS far_id
        ) AS side
        WHERE greatest(line.a_depth, line.b_depth) >= p_near_depth AND geometry.numerator <> 0
            AND side.near_id IS NOT NULL AND p_camera_only = (side.near_id = p_camera_sector)
            AND (line.front_sector_id IS DISTINCT FROM line.back_sector_id OR EXISTS (
                SELECT 1
                FROM doom.line_surfaces AS face
                WHERE face.level_id = p_level_id AND face.line_id = line.line_id
                    AND face.is_back = (geometry.numerator < 0) AND face.middle_material IS NOT NULL
            ))
            AND (least(line.a_depth, line.b_depth) < p_near_depth
                 OR ((line.a_right >= -line.a_depth OR line.b_right >= -line.b_depth)
                     AND (line.a_right <= line.a_depth OR line.b_right <= line.b_depth)))
    )
    SELECT line.line_id, line.near_id, line.far_id, line.wall_color, line.is_back, line.a_depth, line.a_right,
           line.numerator, line.delta_depth, line.delta_right, bounds.first_col, bounds.last_col,
           CASE WHEN abs(edge.right_x - bounds.last_col) <= p_epsilon THEN bounds.last_col END,
           line.vertex_depth, -line.delta_depth * line.vertex_depth / line.numerator
    FROM projected AS line
    CROSS JOIN LATERAL (
        SELECT p_focal * (1 + least(line.a_slope, line.b_slope)) - 0.5 AS left_x,
               p_focal * (1 + greatest(line.a_slope, line.b_slope)) - 0.5 AS right_x
    ) AS edge
    CROSS JOIN LATERAL (
        SELECT least(p_width, greatest(0, floor(edge.left_x + p_epsilon) + 1))::integer AS first_col,
               greatest(-1, least(p_width - 1, floor(edge.right_x + p_epsilon)))::integer AS last_col
    ) AS bounds
    WHERE greatest(p_first_column, bounds.first_col) <= least(p_last_column, bounds.last_col);
$$;
