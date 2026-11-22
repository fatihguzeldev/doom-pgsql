CREATE TYPE doom._ray_boundary AS (
    line_id integer,
    source_sector integer,
    target_sector integer,
    t double precision,
    blocked boolean
);

CREATE FUNCTION doom._ray_sectors(
    p_actor doom.actors, p_dx double precision, p_dy double precision, p_z double precision
)
RETURNS TABLE (sector_id integer, start_t double precision, end_t double precision, end_blocked boolean)
LANGUAGE plpgsql STABLE STRICT PARALLEL SAFE ROWS 16
SET plan_cache_mode = force_generic_plan
AS $$
DECLARE
    vertex_slop constant double precision := 0.00000001;
    bounds_slop constant double precision := 0.00000004;
    ray_dx double precision := CASE WHEN abs(p_dx) >= vertex_slop THEN p_dx ELSE 0 END;
    ray_dy double precision := CASE WHEN abs(p_dy) >= vertex_slop THEN p_dy ELSE 0 END;
    tie_t double precision;
    current_sector integer := p_actor.sector_id;
    crossed_lines integer[] := ARRAY[]::integer[];
    candidates integer[];
    boundaries doom._ray_boundary[];
    boundary doom._ray_boundary;
    hit doom._ray_boundary;
    nearest double precision;
    t double precision;
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
    -- The endpoint/vertex tolerance applies to both the segment and the ray.
    IF greatest(abs(p_actor.x), abs(p_actor.y), abs(ray_dx), abs(ray_dy)) < 1e10 THEN
        candidates := doom._wad_line_candidates(p_actor.level_id,
            p_actor.x + least(0, ray_dx) - bounds_slop, p_actor.y + least(0, ray_dy) - bounds_slop,
            p_actor.x + greatest(0, ray_dx) + bounds_slop, p_actor.y + greatest(0, ray_dy) + bounds_slop);
    END IF;

    -- Resolve each intersection and its live opening once. Walking a portal
    -- changes the allowed source sector, not the ray or the intersection.
    SELECT coalesce(array_agg(ROW(line.line_id, side.source_sector, side.target_sector, position.t,
        line.blocking OR sector.sector_id IS NULL
            OR p_z < coalesce(state.floor_height, sector.floor_height)
            OR p_z >= coalesce(state.ceiling_height, sector.ceiling_height)
    )::doom._ray_boundary), '{}'::doom._ray_boundary[])
    INTO boundaries
    FROM (
        SELECT line.* FROM doom.lines AS line
        WHERE line.level_id = p_actor.level_id AND candidates IS NULL
        UNION ALL
        SELECT line.* FROM unnest(candidates) AS id(line_id)
        JOIN doom.lines AS line ON line.level_id = p_actor.level_id AND line.line_id = id.line_id
    ) AS line
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
    CROSS JOIN LATERAL (
        SELECT CASE WHEN ray.den < 0 THEN line.front_sector_id ELSE line.back_sector_id END AS source_sector,
               CASE WHEN ray.den < 0 THEN line.back_sector_id ELSE line.front_sector_id END AS target_sector
    ) AS side
    LEFT JOIN doom.sectors AS sector
        ON sector.level_id = p_actor.level_id AND sector.sector_id = side.target_sector
    LEFT JOIN doom.sector_state AS state
        ON state.game_id = p_actor.game_id AND state.sector_id = sector.sector_id
    WHERE ray.den <> 0 AND side.source_sector IS NOT NULL
      AND (line.blocking OR line.front_sector_id IS DISTINCT FROM line.back_sector_id)
      AND position.t BETWEEN -tie_t AND 1 + tie_t
      AND position.u BETWEEN 0 AND 1 + ray.tie_u;

    start_t := 0;
    LOOP
        nearest := NULL;
        FOREACH boundary IN ARRAY boundaries LOOP
            IF boundary.source_sector = current_sector AND boundary.t >= start_t - tie_t
                AND boundary.line_id <> ALL (crossed_lines)
            THEN
                t := CASE WHEN boundary.t <= start_t + tie_t THEN start_t ELSE least(1, boundary.t) END;
                nearest := least(nearest, t);
            END IF;
        END LOOP;

        hit := NULL;
        IF nearest IS NOT NULL THEN
            FOREACH boundary IN ARRAY boundaries LOOP
                IF boundary.source_sector = current_sector AND boundary.t >= start_t - tie_t
                    AND boundary.line_id <> ALL (crossed_lines)
                THEN
                    t := CASE WHEN boundary.t <= start_t + tie_t THEN start_t ELSE least(1, boundary.t) END;
                    IF t <= nearest + tie_t AND (hit.line_id IS NULL OR (boundary.blocked AND NOT hit.blocked)
                        OR (boundary.blocked = hit.blocked AND boundary.line_id < hit.line_id))
                    THEN
                        hit := boundary;
                    END IF;
                END IF;
            END LOOP;
        END IF;

        sector_id := current_sector;
        end_t := coalesce(nearest, 1);
        end_blocked := coalesce(hit.blocked, false);
        RETURN NEXT;
        EXIT WHEN hit.line_id IS NULL OR end_blocked;

        -- Several portal crossings can share a vertex. Consume each boundary once at that point.
        IF end_t > start_t THEN
            crossed_lines := ARRAY[hit.line_id];
        ELSE
            crossed_lines := array_append(crossed_lines, hit.line_id);
        END IF;
        current_sector := hit.target_sector;
        start_t := end_t;
    END LOOP;
END;
$$;
