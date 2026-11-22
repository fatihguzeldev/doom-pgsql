CREATE FUNCTION doom._ray_line_action(
    p_player doom.actors, p_activation text, p_reach double precision
)
RETURNS TABLE (line_id integer, distance double precision)
LANGUAGE sql STABLE STRICT ROWS 1
AS $$
    SELECT line.line_id, position.t * p_reach
    FROM doom.line_actions AS action
    JOIN doom.lines AS line USING (level_id, line_id)
    CROSS JOIN LATERAL (SELECT cos(p_player.angle) * p_reach AS dx,
                               sin(p_player.angle) * p_reach AS dy) AS direction
    CROSS JOIN LATERAL (
        SELECT line.x2::double precision - line.x1 AS ex,
               line.y2::double precision - line.y1 AS ey,
               line.x1 - p_player.x AS ox, line.y1 - p_player.y AS oy
    ) AS edge
    CROSS JOIN LATERAL (SELECT direction.dx * edge.ey - direction.dy * edge.ex AS den) AS ray
    CROSS JOIN LATERAL (
        SELECT (edge.ox * edge.ey - edge.oy * edge.ex) / nullif(ray.den, 0) AS t,
               (edge.ox * direction.dy - edge.oy * direction.dx) / nullif(ray.den, 0) AS u
    ) AS position
    JOIN doom._ray_sectors(p_player, direction.dx, direction.dy, doom._eye_z(p_player.z)) AS path
      ON path.sector_id = line.front_sector_id
     AND position.t BETWEEN path.start_t AND path.end_t
    WHERE action.level_id = p_player.level_id AND action.activation = p_activation
      AND ray.den < 0 AND position.u BETWEEN 0 AND 1
    ORDER BY position.t, line.line_id LIMIT 1;
$$;

CREATE FUNCTION doom._activate_line_action(p_player doom.actors, p_line_id integer)
RETURNS doom._line_event
LANGUAGE plpgsql
AS $$
DECLARE
    action doom.line_actions;
    event doom._line_event := ROW(p_player, NULL, false, false);
    destination record;
BEGIN
    SELECT * INTO action FROM doom.line_actions
    WHERE level_id = p_player.level_id AND line_id = p_line_id;
    IF NOT FOUND OR (action.key_kind IS NOT NULL AND NOT EXISTS (
        SELECT FROM doom.game_keys AS key
        WHERE key.game_id = p_player.game_id AND key.key_kind = action.key_kind
    )) THEN
        RETURN event;
    END IF;

    IF action.effect = 'teleport' THEN
        SELECT thing.x, thing.y, thing.angle_deg, sector.sector_id,
               coalesce(state.floor_height, sector.floor_height) AS floor_height
        INTO destination
        FROM doom.wad_line_actions AS raw
        JOIN doom.wad_sector_properties AS target ON target.level_id = raw.level_id AND target.tag = raw.tag
        JOIN doom.sectors AS sector ON sector.level_id = target.level_id AND sector.sector_id = target.sector_id
        JOIN doom.level_things AS thing ON thing.level_id = raw.level_id AND thing.type_code = 14
          AND doom.sector_at(raw.level_id, thing.x, thing.y) = target.sector_id
        LEFT JOIN doom.sector_state AS state ON state.game_id = p_player.game_id AND state.sector_id = target.sector_id
        WHERE raw.level_id = action.level_id AND raw.line_id = action.line_id AND raw.tag <> 0
        ORDER BY target.sector_id, thing.thing_id LIMIT 1;
        IF NOT FOUND THEN
            RETURN event;
        END IF;
    END IF;

    IF action.once_only AND action.effect NOT IN ('normal', 'secret') THEN
        INSERT INTO doom.line_activations (game_id, level_id, line_id)
        VALUES (p_player.game_id, action.level_id, action.line_id)
        ON CONFLICT (game_id, line_id) DO NOTHING;
        IF NOT FOUND THEN
            RETURN event;
        END IF;
    END IF;

    CASE action.effect
        WHEN 'normal', 'secret' THEN
            event.exit_kind := action.effect;
        WHEN 'teleport' THEN
            p_player.x := destination.x;
            p_player.y := destination.y;
            p_player.z := destination.floor_height;
            p_player.angle := radians(destination.angle_deg);
            p_player.sector_id := destination.sector_id;
            event.player := p_player;
        WHEN 'ceiling' THEN
            INSERT INTO doom.ceiling_motions (game_id, level_id, sector_id, target_height,
                                              units_per_tick, return_height, delay_ticks)
            SELECT p_player.game_id, target.level_id, target.sector_id, target.height,
                   action.units_per_tick, target.return_height, action.delay_ticks
            FROM doom.line_action_targets AS target
            WHERE target.level_id = action.level_id AND target.line_id = action.line_id
            ORDER BY target.sector_id
            ON CONFLICT (game_id, sector_id) DO NOTHING;
            event.ceiling_motion := FOUND;
        WHEN 'floor' THEN
            INSERT INTO doom.floor_motions (game_id, level_id, sector_id, target_height,
                                            units_per_tick, return_height, delay_ticks)
            SELECT p_player.game_id, target.level_id, target.sector_id, target.height,
                   action.units_per_tick, target.return_height, action.delay_ticks
            FROM doom.line_action_targets AS target
            WHERE target.level_id = action.level_id AND target.line_id = action.line_id
            ORDER BY target.sector_id
            ON CONFLICT (game_id, sector_id) DO NOTHING;
            event.floor_motion := FOUND;
    END CASE;
    RETURN event;
END;
$$;

CREATE FUNCTION doom._cross_line_actions(p_before doom.actors, p_after doom.actors)
RETURNS doom._line_event
LANGUAGE plpgsql
AS $$
DECLARE
    dx double precision := p_after.x - p_before.x;
    dy double precision := p_after.y - p_before.y;
    line_hit record;
    current_event doom._line_event;
    event doom._line_event := ROW(p_after, NULL, false, false);
BEGIN
    IF dx = 0 AND dy = 0 THEN
        RETURN event;
    END IF;
    FOR line_hit IN
        SELECT line.line_id
        FROM doom.line_actions AS action
        JOIN doom.lines AS line USING (level_id, line_id)
        CROSS JOIN LATERAL (
            SELECT line.x2::double precision - line.x1 AS ex,
                   line.y2::double precision - line.y1 AS ey,
                   line.x1 - p_before.x AS ox, line.y1 - p_before.y AS oy
        ) AS edge
        CROSS JOIN LATERAL (SELECT dx * edge.ey - dy * edge.ex AS den) AS ray
        CROSS JOIN LATERAL (
            SELECT (edge.ox * edge.ey - edge.oy * edge.ex) / nullif(ray.den, 0) AS t,
                   (edge.ox * dy - edge.oy * dx) / nullif(ray.den, 0) AS u
        ) AS position
        WHERE action.level_id = p_before.level_id AND action.activation = 'cross'
          AND (line.front_sector_id IN (p_before.sector_id, p_after.sector_id)
               OR line.back_sector_id IN (p_before.sector_id, p_after.sector_id))
          AND (action.effect <> 'teleport' OR ray.den < 0)
          AND position.t >= 0 AND position.t < 1 AND position.u BETWEEN 0 AND 1
        ORDER BY position.t, line.line_id
    LOOP
        current_event := doom._activate_line_action(event.player, line_hit.line_id);
        event.player := current_event.player;
        event.exit_kind := current_event.exit_kind;
        event.ceiling_motion := event.ceiling_motion OR current_event.ceiling_motion;
        event.floor_motion := event.floor_motion OR current_event.floor_motion;
        EXIT WHEN event.exit_kind IS NOT NULL
            OR (p_after.x, p_after.y) IS DISTINCT FROM ((event.player).x, (event.player).y);
    END LOOP;
    RETURN event;
END;
$$;

CREATE FUNCTION doom._wad_sector_health(p_player doom.actors, p_tick bigint)
RETURNS TABLE (health integer, exits boolean)
LANGUAGE plpgsql
AS $$
DECLARE
    hazard integer;
    damage integer;
BEGIN
    health := p_player.health;
    exits := false;
    SELECT special INTO hazard FROM doom.wad_sector_properties
    WHERE level_id = p_player.level_id AND sector_id = p_player.sector_id
      AND special IN (4, 5, 7, 11, 16);
    IF NOT FOUND OR health <= 0 THEN
        RETURN NEXT;
        RETURN;
    END IF;
    damage := CASE hazard WHEN 5 THEN 10 WHEN 7 THEN 5 ELSE 20 END;
    IF p_tick % 32 = 0 THEN
        IF hazard = 11 THEN
            damage := least(damage, health - 1);
        ELSIF doom._consume_inventory(p_player.game_id, 'hazard-protection', 1) = 1 THEN
            damage := 0;
        END IF;
        IF damage > 0 THEN
            health := coalesce(doom._damage_actor(p_player.game_id, p_player.actor_id, damage, p_tick), health);
        END IF;
    END IF;
    exits := hazard = 11 AND health <= 10;
    RETURN NEXT;
END;
$$;
