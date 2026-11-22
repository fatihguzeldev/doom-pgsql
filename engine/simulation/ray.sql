CREATE FUNCTION doom._ray_sectors(
    p_actor doom.actors, p_dx double precision, p_dy double precision, p_z double precision
)
RETURNS TABLE (sector_id integer, start_t double precision, end_t double precision, end_blocked boolean)
LANGUAGE plpgsql STABLE STRICT PARALLEL SAFE ROWS 16
AS $$
DECLARE
    vertex_slop constant double precision := 0.00000001;
    ray_dx double precision := CASE WHEN abs(p_dx) >= vertex_slop THEN p_dx ELSE 0 END;
    ray_dy double precision := CASE WHEN abs(p_dy) >= vertex_slop THEN p_dy ELSE 0 END;
    tie_t double precision;
    current_sector integer := p_actor.sector_id;
    crossed_lines integer[] := ARRAY[]::integer[];
    hit record;
BEGIN
    IF (ray_dx = 0 AND ray_dy = 0) OR NOT EXISTS (
        SELECT FROM doom.sectors AS sector
        LEFT JOIN doom.sector_state AS state ON state.game_id = p_actor.game_id
            AND state.sector_id = sector.sector_id
        WHERE sector.level_id = p_actor.level_id AND sector.sector_id = current_sector
          AND p_z >= coalesce(state.floor_height, sector.floor_height)
          AND p_z < coalesce(state.ceiling_height, sector.ceiling_height)
    ) THEN
        RETURN;
    END IF;

    tie_t := vertex_slop / greatest(abs(ray_dx), abs(ray_dy));
    start_t := 0;
    LOOP
        WITH intersections AS MATERIALIZED (
            SELECT line.line_id, line.blocking,
                   CASE WHEN line.front_sector_id = current_sector THEN line.back_sector_id
                        ELSE line.front_sector_id END AS neighbor,
                   CASE WHEN position.t <= start_t + tie_t THEN start_t
                        ELSE least(1, position.t) END AS t
            FROM doom.lines AS line
            CROSS JOIN LATERAL (
                SELECT line.x2::double precision - line.x1 AS ex,
                       line.y2::double precision - line.y1 AS ey,
                       line.x1 - p_actor.x AS ox, line.y1 - p_actor.y AS oy
            ) AS edge
            CROSS JOIN LATERAL (
                SELECT ray_dx * edge.ey - ray_dy * edge.ex AS den,
                       edge.ox * edge.ey - edge.oy * edge.ex AS t_num,
                       edge.ox * ray_dy - edge.oy * ray_dx AS u_num,
                       vertex_slop / greatest(abs(edge.ex), abs(edge.ey)) AS tie_u
            ) AS ray
            CROSS JOIN LATERAL (
                -- Bound the ratios before division so distant, nearly parallel lines cannot overflow.
                SELECT CASE WHEN abs(ray.t_num) <= abs(ray.den) * tie_t THEN 0
                            WHEN abs(ray.t_num) <= abs(ray.den) * 2
                            THEN ray.t_num / nullif(ray.den, 0) END AS t,
                       CASE WHEN abs(ray.u_num) <= abs(ray.den) * ray.tie_u THEN 0
                            WHEN abs(ray.u_num) <= abs(ray.den) * 2
                            THEN ray.u_num / nullif(ray.den, 0) END AS u
            ) AS position
            WHERE line.level_id = p_actor.level_id
              AND ((line.front_sector_id = current_sector AND ray.den < 0)
                   OR (line.back_sector_id = current_sector AND ray.den > 0))
              AND (line.blocking OR line.front_sector_id IS DISTINCT FROM line.back_sector_id)
              AND line.line_id <> ALL (crossed_lines)
              AND position.t BETWEEN start_t - tie_t AND 1 + tie_t
              AND position.u BETWEEN 0 AND 1 + ray.tie_u
        ), nearest AS (
            SELECT min(intersection.t) AS t FROM intersections AS intersection
        )
        SELECT line.line_id, line.neighbor, nearest.t,
               line.blocking OR sector.sector_id IS NULL
                   OR p_z < coalesce(state.floor_height, sector.floor_height)
                   OR p_z >= coalesce(state.ceiling_height, sector.ceiling_height) AS blocked
        INTO hit
        FROM nearest
        JOIN intersections AS line ON line.t <= nearest.t + tie_t
        LEFT JOIN doom.sectors AS sector
            ON sector.level_id = p_actor.level_id AND sector.sector_id = line.neighbor
        LEFT JOIN doom.sector_state AS state
            ON state.game_id = p_actor.game_id AND state.sector_id = sector.sector_id
        ORDER BY blocked DESC, line.line_id
        LIMIT 1;

        sector_id := current_sector;
        end_t := coalesce(hit.t, 1);
        end_blocked := coalesce(hit.blocked, false);
        RETURN NEXT;
        EXIT WHEN hit.line_id IS NULL OR end_blocked;

        -- Several portal crossings can share a vertex. Consume each boundary once at that point.
        IF end_t > start_t THEN
            crossed_lines := ARRAY[hit.line_id];
        ELSE
            crossed_lines := array_append(crossed_lines, hit.line_id);
        END IF;
        current_sector := hit.neighbor;
        start_t := end_t;
    END LOOP;
END;
$$;
