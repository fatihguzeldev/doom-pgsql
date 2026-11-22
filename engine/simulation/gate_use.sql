CREATE FUNCTION doom._use_gate(p_actor doom.actors)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    reach CONSTANT double precision := 64;
    corner_tolerance CONSTANT double precision := 0.00000001;
    ray_x double precision;
    ray_y double precision;
    selected_gate record;
BEGIN
    IF NOT EXISTS (SELECT FROM doom.gate_controls WHERE level_id = p_actor.level_id) THEN
        RETURN false;
    END IF;

    ray_x := cos(p_actor.angle);
    ray_y := sin(p_actor.angle);
    -- Treat axis drift smaller than the endpoint tolerance as parallel.
    IF abs(ray_x) * reach < corner_tolerance THEN
        ray_x := 0;
    ELSIF abs(ray_y) * reach < corner_tolerance THEN
        ray_y := 0;
    END IF;

    WITH hits AS (
        SELECT line.line_id, control.sector_id, position.distance,
               control.line_id IS NULL AND (line.blocking OR line.back_sector_id IS NULL) AS occludes
        FROM doom.lines AS line
        LEFT JOIN doom.gate_controls AS control USING (level_id, line_id)
        CROSS JOIN LATERAL (
            SELECT line.x2::double precision - line.x1 AS dx,
                   line.y2::double precision - line.y1 AS dy,
                   line.x1 - p_actor.x AS ox, line.y1 - p_actor.y AS oy
        ) AS edge
        CROSS JOIN LATERAL (SELECT ray_x * edge.dy - ray_y * edge.dx AS denominator) AS ray
        CROSS JOIN LATERAL (
            SELECT (edge.ox * edge.dy - edge.oy * edge.dx) / nullif(ray.denominator, 0) AS distance,
                   (edge.ox * ray_y - edge.oy * ray_x) / nullif(ray.denominator, 0) AS fraction,
                   corner_tolerance / greatest(abs(edge.dx), abs(edge.dy)) AS end_tolerance
        ) AS position
        WHERE line.level_id = p_actor.level_id
          AND ((line.front_sector_id = p_actor.sector_id AND ray.denominator < 0)
               OR (line.back_sector_id = p_actor.sector_id AND ray.denominator > 0))
          AND (control.line_id IS NOT NULL OR line.blocking OR line.front_sector_id IS DISTINCT FROM line.back_sector_id)
          AND position.distance BETWEEN 0 AND reach
          AND position.fraction BETWEEN -position.end_tolerance AND 1 + position.end_tolerance
    ), first_hit AS (
        SELECT sector_id
        FROM (SELECT hits.*, min(distance) OVER () AS nearest_distance FROM hits) AS hit
        WHERE distance <= nearest_distance + corner_tolerance
        -- An opaque wall at a shared vertex takes precedence over a control.
        ORDER BY occludes DESC, (sector_id IS NOT NULL) DESC, line_id
        LIMIT 1
    )
    SELECT gate.*, coalesce(state.ceiling_height, sector.ceiling_height) AS current_ceiling
    INTO selected_gate
    FROM first_hit AS hit
    JOIN doom.gates AS gate ON gate.level_id = p_actor.level_id AND gate.sector_id = hit.sector_id
    JOIN doom.sectors AS sector ON sector.level_id = gate.level_id AND sector.sector_id = gate.sector_id
    LEFT JOIN doom.sector_state AS state
        ON state.game_id = p_actor.game_id AND state.sector_id = gate.sector_id;

    IF NOT FOUND THEN
        RETURN false;
    END IF;

    INSERT INTO doom.ceiling_motions AS motion (game_id, level_id, sector_id, target_height, units_per_tick)
    VALUES (p_actor.game_id, p_actor.level_id, selected_gate.sector_id,
            CASE WHEN selected_gate.current_ceiling >= selected_gate.open_ceiling
                 THEN selected_gate.closed_ceiling ELSE selected_gate.open_ceiling END,
            selected_gate.units_per_tick)
    ON CONFLICT (game_id, sector_id) DO UPDATE
    SET target_height = CASE WHEN motion.target_height = selected_gate.open_ceiling
                             THEN selected_gate.closed_ceiling ELSE selected_gate.open_ceiling END,
        units_per_tick = EXCLUDED.units_per_tick;

    RETURN true;
END;
$$;
