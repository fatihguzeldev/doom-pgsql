CREATE FUNCTION doom._eye_z(p_feet_z double precision)
RETURNS double precision LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
RETURN p_feet_z + 41;

CREATE FUNCTION doom._circle_segment_contact(
    p_x double precision, p_y double precision,
    p_dx double precision, p_dy double precision, p_radius double precision,
    p_x1 double precision, p_y1 double precision, p_x2 double precision, p_y2 double precision
)
RETURNS double precision
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
AS $$
DECLARE
    roundoff CONSTANT double precision := 8.881784197001252e-16;
    edge_x double precision;
    edge_y double precision;
    edge_squared double precision;
    start_x double precision;
    start_y double precision;
    end_x double precision;
    end_y double precision;
    projection double precision;
    projection_motion double precision;
    contact_projection double precision;
    line_offset double precision;
    strip_radius double precision;
    toward_line double precision;
    gap double precision;
    contact double precision;
    radius_squared double precision;
    endpoint_x double precision;
    endpoint_y double precision;
    toward_endpoint double precision;
    endpoint_squared double precision;
    radius_motion_squared double precision;
    cross_x double precision;
    cross_y double precision;
    cross_motion double precision;
    discriminant double precision;
    root_scale double precision;
    earliest double precision;
BEGIN
    IF p_radius <= 0 OR (p_dx = 0 AND p_dy = 0)
        OR greatest(abs(p_x), abs(p_y), abs(p_dx), abs(p_dy), p_radius,
                    abs(p_x1), abs(p_y1), abs(p_x2), abs(p_y2)) >= 'Infinity'
    THEN
        RETURN NULL;
    END IF;

    edge_x := p_x2 - p_x1;
    edge_y := p_y2 - p_y1;
    edge_squared := edge_x * edge_x + edge_y * edge_y;
    start_x := p_x - p_x1;
    start_y := p_y - p_y1;
    end_x := p_x - p_x2;
    end_y := p_y - p_y2;
    projection := start_x * edge_x + start_y * edge_y;
    radius_squared := p_radius * p_radius;

    -- From an existing overlap the squared distance to the segment is convex
    -- in time, so only an initially inward velocity can deepen the overlap.
    IF edge_squared = 0 OR projection <= 0 OR projection >= edge_squared THEN
        IF projection > 0 THEN
            endpoint_x := end_x;
            endpoint_y := end_y;
        ELSE
            endpoint_x := start_x;
            endpoint_y := start_y;
        END IF;

        IF endpoint_x * endpoint_x + endpoint_y * endpoint_y <= radius_squared THEN
            RETURN CASE WHEN endpoint_x * p_dx + endpoint_y * p_dy < 0 THEN 0.0 END;
        END IF;
    END IF;

    IF edge_squared > 0 THEN
        line_offset := start_x * edge_y - start_y * edge_x;
        strip_radius := p_radius * sqrt(edge_squared);
        toward_line := p_dy * edge_x - p_dx * edge_y;
        IF line_offset < 0 THEN
            toward_line := -toward_line;
        END IF;
        gap := abs(line_offset) - strip_radius;

        IF gap <= 0 AND projection BETWEEN 0 AND edge_squared THEN
            RETURN CASE WHEN line_offset <> 0 AND toward_line > 0 THEN 0.0 END;
        END IF;

        projection_motion := p_dx * edge_x + p_dy * edge_y;
        IF gap > 0 AND toward_line > 0
            AND gap - toward_line <= roundoff * (abs(line_offset) + strip_radius)
        THEN
            contact := CASE WHEN gap >= toward_line THEN 1.0 ELSE gap / toward_line END;
            contact_projection := projection + contact * projection_motion;
            IF contact_projection BETWEEN 0 AND edge_squared THEN
                -- Before reaching the strip the center is outside both endpoint disks.
                RETURN contact;
            END IF;
        END IF;

        IF projection BETWEEN 0 AND edge_squared
            AND projection + projection_motion BETWEEN 0 AND edge_squared
        THEN
            RETURN NULL;
        END IF;
    END IF;

    radius_motion_squared := radius_squared * (p_dx * p_dx + p_dy * p_dy);
    FOR endpoint IN 1..2 LOOP
        IF endpoint = 1 THEN
            endpoint_x := start_x;
            endpoint_y := start_y;
        ELSE
            EXIT WHEN edge_squared = 0;
            endpoint_x := end_x;
            endpoint_y := end_y;
        END IF;

        toward_endpoint := -(endpoint_x * p_dx + endpoint_y * p_dy);
        IF toward_endpoint > 0 THEN
            cross_x := endpoint_x * p_dy;
            cross_y := endpoint_y * p_dx;
            cross_motion := cross_x - cross_y;
            discriminant := radius_motion_squared - cross_motion * cross_motion;
            -- Roundoff in the determinant can place an exact graze just inside the disk.
            IF discriminant > roundoff * (radius_motion_squared + abs(cross_motion) * (abs(cross_x) + abs(cross_y))) THEN
                -- The equivalent near root avoids cancellation next to the boundary.
                endpoint_squared := endpoint_x * endpoint_x + endpoint_y * endpoint_y;
                gap := endpoint_squared - radius_squared;
                root_scale := toward_endpoint + sqrt(discriminant);
                IF gap - root_scale <= roundoff * (endpoint_squared + radius_squared) THEN
                    contact := CASE WHEN gap >= root_scale THEN 1.0 ELSE greatest(0.0, gap) / root_scale END;
                    earliest := least(earliest, contact);
                END IF;
            END IF;
        END IF;
    END LOOP;

    RETURN earliest;
END;
$$;

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

CREATE FUNCTION doom._movement_lines(p_level_id bigint, p_candidates integer[])
RETURNS SETOF doom.lines
LANGUAGE sql STABLE PARALLEL SAFE
AS $$
    SELECT line.* FROM unnest(p_candidates) AS candidate(line_id)
    JOIN doom.lines AS line ON line.level_id = p_level_id AND line.line_id = candidate.line_id
$$;

CREATE FUNCTION doom._move_actor(
    p_actor doom.actors, p_dx double precision, p_dy double precision, p_height double precision,
    p_radius double precision
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
    candidates integer[];
BEGIN
    IF p_radius IS NULL OR p_radius < 0 OR p_radius >= 'Infinity' THEN
        RAISE EXCEPTION 'invalid movement radius' USING ERRCODE = '22023';
    END IF;

    IF p_dx = 0 AND p_dy = 0 THEN
        RETURN p_actor;
    END IF;

    IF greatest(abs(p_actor.x), abs(p_actor.y), abs(p_dx), abs(p_dy), p_radius) < 1e10 THEN
        candidates := ARRAY(SELECT doom._wad_line_candidates(p_actor.level_id,
            p_actor.x + least(0, p_dx) - p_radius - boundary_slop,
            p_actor.y + least(0, p_dy) - p_radius - boundary_slop,
            p_actor.x + greatest(0, p_dx) + p_radius + boundary_slop,
            p_actor.y + greatest(0, p_dy) + p_radius + boundary_slop));
    END IF;

    -- An empty swept box keeps the entire body in the current sector.
    IF p_radius > 0 AND NOT EXISTS (
        SELECT FROM doom._movement_lines(p_actor.level_id, candidates)
        WHERE (front_sector_id = p_actor.sector_id OR back_sector_id = p_actor.sector_id)
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
        FROM doom._movement_lines(p_actor.level_id, candidates) AS line
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
        WHERE (line.blocking OR line.front_sector_id IS DISTINCT FROM line.back_sector_id)
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
                FROM doom._movement_lines(p_actor.level_id, candidates)
                WHERE (blocking OR front_sector_id IS DISTINCT FROM back_sector_id)
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


CREATE FUNCTION doom._actor_contact(
    p_actor doom.actors, p_dx double precision, p_dy double precision,
    p_height double precision, p_radius double precision
)
RETURNS double precision
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    candidate record;
    contact_actor doom.actors := p_actor;
    reached doom.actors;
    left_x double precision := least(p_actor.x, p_actor.x + p_dx) - p_radius;
    right_x double precision := greatest(p_actor.x, p_actor.x + p_dx) + p_radius;
    bottom_y double precision := least(p_actor.y, p_actor.y + p_dy) - p_radius;
    top_y double precision := greatest(p_actor.y, p_actor.y + p_dy) + p_radius;
BEGIN
    IF p_actor IS NULL OR p_dx IS NULL OR p_dy IS NULL OR p_height IS NULL
        OR p_radius IS NULL OR p_radius <= 0 OR (p_dx = 0 AND p_dy = 0)
    THEN
        RETURN NULL;
    END IF;

    FOR candidate IN
        SELECT body.x, body.y, body.sector_id,
               doom._circle_segment_contact(p_actor.x, p_actor.y, p_dx, p_dy, p_radius + kind.radius,
                                            body.x, body.y, body.x, body.y) AS contact_at
        FROM doom.actors AS body
        JOIN doom.thing_types AS kind ON kind.type_id = body.type_id
        WHERE body.game_id = p_actor.game_id AND body.life_state = 'alive' AND kind.blocks_actors
          AND body.cell_x BETWEEN floor((left_x - 32) / 64)::integer
                              AND floor((right_x + 32) / 64)::integer
          AND body.actor_id <> p_actor.actor_id
          AND body.x BETWEEN left_x - kind.radius AND right_x + kind.radius
          AND body.y BETWEEN bottom_y - kind.radius AND top_y + kind.radius
          AND body.z < p_actor.z + p_height AND body.z + kind.height > p_actor.z
        ORDER BY contact_at
    LOOP
        EXIT WHEN candidate.contact_at IS NULL;

        -- A wall can separate overlapping disks, even within one sector.
        contact_actor.x := p_actor.x + p_dx * candidate.contact_at;
        contact_actor.y := p_actor.y + p_dy * candidate.contact_at;
        reached := doom._move_actor(contact_actor, candidate.x - contact_actor.x,
                                    candidate.y - contact_actor.y, p_height, 0);
        IF reached.sector_id = candidate.sector_id
            AND abs(reached.x - candidate.x) < 0.000001 AND abs(reached.y - candidate.y) < 0.000001
        THEN
            RETURN candidate.contact_at;
        END IF;
    END LOOP;

    RETURN NULL;
END;
$$;

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
        candidates := ARRAY(SELECT doom._wad_line_candidates(p_actor.level_id,
            p_actor.x + least(0, ray_dx) - bounds_slop, p_actor.y + least(0, ray_dy) - bounds_slop,
            p_actor.x + greatest(0, ray_dx) + bounds_slop, p_actor.y + greatest(0, ray_dy) + bounds_slop));
    END IF;

    -- Resolve each intersection and its live opening once. Walking a portal
    -- changes the allowed source sector, not the ray or the intersection.
    SELECT coalesce(array_agg(ROW(line.line_id, side.source_sector, side.target_sector, position.t,
        line.blocking OR sector.sector_id IS NULL
            OR p_z < coalesce(state.floor_height, sector.floor_height)
            OR p_z >= coalesce(state.ceiling_height, sector.ceiling_height)
    )::doom._ray_boundary), '{}'::doom._ray_boundary[])
    INTO boundaries
    FROM doom._movement_lines(p_actor.level_id, candidates) AS line
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
