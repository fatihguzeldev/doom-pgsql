CREATE FUNCTION doom.move_actor(
    p_actor doom.actors, p_dx double precision, p_dy double precision, p_height double precision
)
RETURNS doom.actors
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    hit record;
    floor_at_destination integer;
    ceiling_at_opening integer;
    traversed double precision := '-Infinity';
    crossed_lines integer[] := ARRAY[]::integer[];
    stop_at double precision := 1;
BEGIN
    LOOP
        SELECT line.line_id, line.blocking, position.t,
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
          AND position.t BETWEEN 0 AND 1
          AND position.t >= traversed
          AND line.line_id <> ALL (crossed_lines)
        ORDER BY position.t, (line.blocking OR line.back_sector_id IS NULL) DESC, line.line_id
        LIMIT 1;

        EXIT WHEN NOT FOUND;

        IF NOT hit.blocking AND hit.neighbor IS NOT NULL THEN
            SELECT coalesce(target_state.floor_height, target.floor_height),
                   least(coalesce(origin_state.ceiling_height, origin.ceiling_height),
                         coalesce(target_state.ceiling_height, target.ceiling_height))
            INTO STRICT floor_at_destination, ceiling_at_opening
            FROM doom.sectors AS origin
            JOIN doom.sectors AS target ON target.level_id = origin.level_id AND target.sector_id = hit.neighbor
            LEFT JOIN doom.sector_state AS origin_state
                ON origin_state.game_id = p_actor.game_id AND origin_state.sector_id = origin.sector_id
            LEFT JOIN doom.sector_state AS target_state
                ON target_state.game_id = p_actor.game_id AND target_state.sector_id = target.sector_id
            WHERE origin.level_id = p_actor.level_id AND origin.sector_id = p_actor.sector_id;

            IF floor_at_destination <= p_actor.z + 16
                AND greatest(p_actor.z, floor_at_destination) + p_height <= ceiling_at_opening
            THEN
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
        stop_at := greatest(0, traversed, hit.t - 0.00001 / sqrt(p_dx * p_dx + p_dy * p_dy));
        EXIT;
    END LOOP;

    p_actor.x := p_actor.x + stop_at * p_dx;
    p_actor.y := p_actor.y + stop_at * p_dy;
    RETURN p_actor;
END;
$$;
