CREATE FUNCTION doom._portal_floor(
    p_game_id bigint, p_level_id bigint, p_origin integer, p_target integer,
    p_z double precision, p_height double precision
)
RETURNS TABLE (floor_height integer)
LANGUAGE sql STABLE PARALLEL SAFE ROWS 1
AS $$
    SELECT coalesce(target_state.floor_height, target.floor_height)
    FROM doom.sectors AS origin
    JOIN doom.sectors AS target ON target.level_id = origin.level_id AND target.sector_id = p_target
    JOIN doom.levels AS level ON level.level_id = origin.level_id
    LEFT JOIN doom.sector_state AS origin_state
        ON origin_state.game_id = p_game_id AND origin_state.sector_id = origin.sector_id
    LEFT JOIN doom.sector_state AS target_state
        ON target_state.game_id = p_game_id AND target_state.sector_id = target.sector_id
    WHERE origin.level_id = p_level_id AND origin.sector_id = p_origin
      AND coalesce(target_state.floor_height, target.floor_height) <= p_z + level.step_height
      AND greatest(p_z, coalesce(target_state.floor_height, target.floor_height)) + p_height
          <= least(coalesce(origin_state.ceiling_height, origin.ceiling_height),
                   coalesce(target_state.ceiling_height, target.ceiling_height))
$$;

CREATE FUNCTION doom.move_actor(
    p_actor doom.actors, p_dx double precision, p_dy double precision, p_height double precision,
    p_radius double precision DEFAULT 0
)
RETURNS doom.actors
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    clearance CONSTANT double precision := 0.00001;
    boundary_slop CONSTANT double precision := 0.00000001;
    start_slop double precision := boundary_slop / greatest(1.0, abs(p_dx), abs(p_dy));
    hit record;
    floor_at_destination integer;
    traversed double precision := '-Infinity';
    crossed_lines integer[] := ARRAY[]::integer[];
    stop_at double precision := 1;
    segment_start double precision;
    segment_end double precision;
    start_x double precision;
    start_y double precision;
    end_x double precision;
    end_y double precision;
    sweep lseg;
    contact_at double precision;
    actor_on_segment doom.actors;
BEGIN
    IF p_radius IS NULL OR p_radius < 0 OR p_radius >= 'Infinity' THEN
        RAISE EXCEPTION 'invalid movement radius' USING ERRCODE = '22023';
    END IF;

    IF p_dx = 0 AND p_dy = 0 THEN
        RETURN p_actor;
    END IF;

    -- An empty swept box keeps the entire body in the current sector.
    IF p_radius > 0 AND NOT EXISTS (
        SELECT FROM doom.lines
        WHERE level_id = p_actor.level_id
          AND (front_sector_id = p_actor.sector_id OR back_sector_id = p_actor.sector_id)
          AND (blocking OR front_sector_id IS DISTINCT FROM back_sector_id)
          AND least(x1, x2) <= greatest(p_actor.x, p_actor.x + p_dx) + p_radius
          AND greatest(x1, x2) >= least(p_actor.x, p_actor.x + p_dx) - p_radius
          AND least(y1, y2) <= greatest(p_actor.y, p_actor.y + p_dy) + p_radius
          AND greatest(y1, y2) >= least(p_actor.y, p_actor.y + p_dy) - p_radius
    ) THEN
        contact_at := doom._actor_contact(p_actor, p_dx, p_dy, p_height, p_radius);
        IF contact_at IS NOT NULL THEN
            stop_at := greatest(0, contact_at - clearance / sqrt(p_dx * p_dx + p_dy * p_dy));
        END IF;
        p_actor.x := p_actor.x + stop_at * p_dx;
        p_actor.y := p_actor.y + stop_at * p_dy;
        RETURN p_actor;
    END IF;

    LOOP
        SELECT line.line_id, line.blocking, greatest(0, position.t) AS t,
               CASE WHEN line.front_sector_id = p_actor.sector_id THEN line.back_sector_id
                    ELSE line.front_sector_id END AS neighbor
        INTO hit
        FROM doom.lines AS line
        CROSS JOIN LATERAL (
            SELECT line.x2::double precision - line.x1 AS ex,
                   line.y2::double precision - line.y1 AS ey,
                   line.x1 - p_actor.x AS ox, line.y1 - p_actor.y AS oy
        ) AS edge
        CROSS JOIN LATERAL (SELECT p_dx * edge.ey - p_dy * edge.ex AS den) AS ray
        CROSS JOIN LATERAL (
            SELECT (edge.ox * edge.ey - edge.oy * edge.ex) / nullif(ray.den, 0) AS t,
                   (edge.ox * p_dy - edge.oy * p_dx) / nullif(ray.den, 0) AS u
        ) AS position
        WHERE line.level_id = p_actor.level_id
          AND (line.blocking OR line.front_sector_id IS DISTINCT FROM line.back_sector_id)
          AND ((line.front_sector_id = p_actor.sector_id AND ray.den < 0)
               OR (line.back_sector_id = p_actor.sector_id AND ray.den > 0))
          AND position.u BETWEEN 0 AND 1
          AND position.t BETWEEN -start_slop AND 1
          AND greatest(0, position.t) >= traversed
          AND line.line_id <> ALL (crossed_lines)
        ORDER BY t, (line.blocking OR line.back_sector_id IS NULL) DESC, line.line_id
        LIMIT 1;

        segment_start := greatest(0, traversed);
        segment_end := coalesce(hit.t, 1);
        IF p_radius > 0 AND segment_end > segment_start AND (p_dx <> 0 OR p_dy <> 0) THEN
            start_x := p_actor.x + p_dx * segment_start;
            start_y := p_actor.y + p_dy * segment_start;
            end_x := p_actor.x + p_dx * segment_end;
            end_y := p_actor.y + p_dy * segment_end;
            sweep := lseg(point(start_x, start_y), point(end_x, end_y));

            -- The actor can touch an adjacent wall before its center enters that sector.
            WITH RECURSIVE nearby AS NOT MATERIALIZED (
                SELECT line_id, x1, y1, x2, y2, front_sector_id, back_sector_id, blocking
                FROM doom.lines
                WHERE level_id = p_actor.level_id
                  AND (blocking OR front_sector_id IS DISTINCT FROM back_sector_id)
                  AND least(x1, x2) <= greatest(start_x, end_x) + p_radius
                  AND greatest(x1, x2) >= least(start_x, end_x) - p_radius
                  AND least(y1, y2) <= greatest(start_y, end_y) + p_radius
                  AND greatest(y1, y2) >= least(start_y, end_y) - p_radius
            ), reachable (sector_id) AS (
                VALUES (p_actor.sector_id)
                UNION
                SELECT side.neighbor
                FROM reachable AS sector
                CROSS JOIN LATERAL (
                    SELECT * FROM nearby WHERE front_sector_id = sector.sector_id
                    UNION ALL
                    SELECT * FROM nearby WHERE back_sector_id = sector.sector_id
                        AND front_sector_id <> sector.sector_id
                    OFFSET 0
                ) AS line
                CROSS JOIN LATERAL (
                    SELECT CASE WHEN line.front_sector_id = sector.sector_id THEN line.back_sector_id
                                ELSE line.front_sector_id END AS neighbor
                ) AS side
                WHERE CASE WHEN NOT line.blocking AND side.neighbor IS NOT NULL
                            AND sweep <-> lseg(point(line.x1, line.y1), point(line.x2, line.y2)) < p_radius
                    THEN EXISTS (SELECT FROM doom._portal_floor(p_actor.game_id, p_actor.level_id,
                                                                 sector.sector_id, side.neighbor, p_actor.z, p_height))
                    ELSE false END
            )
            SELECT min(doom._circle_segment_contact(start_x, start_y, end_x - start_x, end_y - start_y,
                                                   p_radius, line.x1, line.y1, line.x2, line.y2))
            INTO contact_at
            FROM reachable AS sector
            CROSS JOIN LATERAL (
                SELECT * FROM nearby WHERE front_sector_id = sector.sector_id
                UNION ALL
                SELECT * FROM nearby WHERE back_sector_id = sector.sector_id
                    AND front_sector_id <> sector.sector_id
                OFFSET 0
            ) AS line
            CROSS JOIN LATERAL (
                SELECT line.x2::double precision - line.x1 AS dx,
                       line.y2::double precision - line.y1 AS dy
            ) AS edge
            -- An accepted drop can make its own portal impassable in reverse. The body
            -- is still allowed to move away from that edge, including from a rounded boundary.
            WHERE line.line_id <> ALL (crossed_lines)
              AND CASE WHEN line.blocking OR line.back_sector_id IS NULL THEN true
                       WHEN EXISTS (SELECT FROM doom._portal_floor(p_actor.game_id, p_actor.level_id,
                           sector.sector_id, CASE WHEN line.front_sector_id = sector.sector_id
                                                 THEN line.back_sector_id ELSE line.front_sector_id END,
                           p_actor.z, p_height)) THEN false
                       ELSE NOT (sector.sector_id = p_actor.sector_id
                         AND abs((start_x - line.x1) * edge.dy - (start_y - line.y1) * edge.dx)
                             <= boundary_slop * greatest(abs(edge.dx), abs(edge.dy))
                         AND (start_x - line.x1) * edge.dx + (start_y - line.y1) * edge.dy
                             BETWEEN 0 AND edge.dx * edge.dx + edge.dy * edge.dy
                         AND CASE WHEN line.front_sector_id = p_actor.sector_id
                                  THEN p_dx * edge.dy - p_dy * edge.dx > 0
                                  ELSE p_dx * edge.dy - p_dy * edge.dx < 0 END) END;

            -- Portal crossings update the floor and sector; x and y still anchor the whole move.
            actor_on_segment := p_actor;
            actor_on_segment.x := start_x;
            actor_on_segment.y := start_y;
            contact_at := least(contact_at, doom._actor_contact(actor_on_segment, end_x - start_x,
                                                               end_y - start_y, p_height, p_radius));
            IF contact_at IS NOT NULL THEN
                stop_at := greatest(segment_start,
                    segment_start + contact_at * (segment_end - segment_start)
                    - clearance / sqrt(p_dx * p_dx + p_dy * p_dy));
                EXIT;
            END IF;
        END IF;

        EXIT WHEN hit.line_id IS NULL;

        IF NOT hit.blocking AND hit.neighbor IS NOT NULL THEN
            SELECT floor_height INTO floor_at_destination
            FROM doom._portal_floor(p_actor.game_id, p_actor.level_id, p_actor.sector_id,
                                    hit.neighbor, p_actor.z, p_height);
            IF floor_at_destination IS NOT NULL THEN
                p_actor.sector_id := hit.neighbor;
                p_actor.z := floor_at_destination;
                -- Several boundaries can meet at one point. Consume each at most once there.
                IF hit.t > traversed THEN
                    crossed_lines := ARRAY[hit.line_id];
                ELSE
                    crossed_lines := array_append(crossed_lines, hit.line_id);
                END IF;
                traversed := hit.t;
                CONTINUE;
            END IF;
        END IF;

        -- Keep the actor on the near side of a solid boundary.
        stop_at := greatest(0, traversed, hit.t - clearance / sqrt(p_dx * p_dx + p_dy * p_dy));
        EXIT;
    END LOOP;

    p_actor.x := p_actor.x + stop_at * p_dx;
    p_actor.y := p_actor.y + stop_at * p_dy;
    RETURN p_actor;
END;
$$;
