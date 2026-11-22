CREATE TABLE doom.compiled_line_actions (
    level_id bigint PRIMARY KEY REFERENCES doom.levels ON DELETE CASCADE
);

CREATE TABLE doom.line_actions (
    level_id bigint NOT NULL,
    line_id integer NOT NULL,
    activation text NOT NULL CHECK (activation IN ('use', 'cross', 'shoot')),
    effect text NOT NULL CHECK (effect IN ('ceiling', 'floor', 'normal', 'secret', 'teleport')),
    once_only boolean NOT NULL,
    key_kind text CHECK (key_kind IN ('blue', 'yellow', 'red')),
    units_per_tick integer NOT NULL CHECK (units_per_tick > 0),
    delay_ticks integer NOT NULL CHECK (delay_ticks >= 0),
    PRIMARY KEY (level_id, line_id),
    FOREIGN KEY (level_id, line_id) REFERENCES doom.lines ON DELETE CASCADE
);

CREATE INDEX line_actions_by_activation ON doom.line_actions (level_id, activation, line_id);

CREATE TABLE doom.line_action_targets (
    level_id bigint NOT NULL,
    line_id integer NOT NULL,
    sector_id integer NOT NULL,
    height integer NOT NULL,
    return_height integer,
    PRIMARY KEY (level_id, line_id, sector_id),
    FOREIGN KEY (level_id, line_id) REFERENCES doom.line_actions ON DELETE CASCADE,
    FOREIGN KEY (level_id, sector_id) REFERENCES doom.sectors ON DELETE CASCADE
);

CREATE TABLE doom.line_activations (
    game_id bigint NOT NULL,
    level_id bigint NOT NULL,
    line_id integer NOT NULL,
    PRIMARY KEY (game_id, line_id),
    FOREIGN KEY (game_id, level_id) REFERENCES doom.games (game_id, level_id) ON DELETE CASCADE,
    FOREIGN KEY (level_id, line_id) REFERENCES doom.line_actions ON DELETE CASCADE
);

CREATE TABLE doom.sector_motions (
    game_id bigint NOT NULL,
    level_id bigint NOT NULL,
    sector_id integer NOT NULL,
    plane text NOT NULL CHECK (plane IN ('ceiling', 'floor')),
    target_height integer NOT NULL,
    units_per_tick integer NOT NULL CHECK (units_per_tick > 0),
    return_height integer,
    delay_ticks integer NOT NULL CHECK (delay_ticks >= 0),
    resume_at_tick bigint NOT NULL DEFAULT 0 CHECK (resume_at_tick >= 0),
    PRIMARY KEY (game_id, sector_id, plane),
    FOREIGN KEY (game_id, level_id) REFERENCES doom.games (game_id, level_id) ON DELETE CASCADE,
    FOREIGN KEY (level_id, sector_id) REFERENCES doom.sectors ON DELETE CASCADE
);

CREATE TYPE doom._line_event AS (
    player doom.actors,
    exit_kind text
);

CREATE FUNCTION doom._bind_wad_actions(p_level_id bigint)
RETURNS void
LANGUAGE plpgsql STRICT
AS $$
BEGIN
    INSERT INTO doom.line_actions (level_id, line_id, activation, effect, once_only,
                                   key_kind, units_per_tick, delay_ticks)
    SELECT raw.level_id, raw.line_id, rule.activation, rule.effect, rule.once_only,
           rule.key_kind, rule.units_per_tick, rule.delay_ticks
    FROM doom.wad_line_actions AS raw
    JOIN (VALUES
        (1,   'use',   'ceiling', false, NULL,     2, 150),
        (2,   'cross', 'ceiling', true,  NULL,     2,   0),
        (3,   'cross', 'ceiling', true,  NULL,     2,   0),
        (4,   'cross', 'ceiling', true,  NULL,     2, 150),
        (5,   'cross', 'floor',   true,  NULL,     1,   0),
        (7,   'use',   'floor',   true,  NULL,     1,   0),
        (8,   'cross', 'floor',   true,  NULL,     1,   0),
        (9,   'use',   'floor',   true,  NULL,     1,   0),
        (10,  'cross', 'floor',   true,  NULL,     4, 105),
        (11,  'use',   'normal',  true,  NULL,     1,   0),
        (16,  'cross', 'ceiling', true,  NULL,     2, 1050),
        (18,  'use',   'floor',   true,  NULL,     1,   0),
        (20,  'use',   'floor',   true,  NULL,     1,   0),
        (21,  'use',   'floor',   true,  NULL,     4, 105),
        (22,  'cross', 'floor',   true,  NULL,     1,   0),
        (23,  'use',   'floor',   true,  NULL,     1,   0),
        (26,  'use',   'ceiling', false, 'blue',   2, 150),
        (27,  'use',   'ceiling', false, 'yellow', 2, 150),
        (28,  'use',   'ceiling', false, 'red',    2, 150),
        (29,  'use',   'ceiling', true,  NULL,     2, 150),
        (31,  'use',   'ceiling', true,  NULL,     2,   0),
        (32,  'use',   'ceiling', true,  'blue',   2,   0),
        (33,  'use',   'ceiling', true,  'red',    2,   0),
        (34,  'use',   'ceiling', true,  'yellow', 2,   0),
        (36,  'cross', 'floor',   true,  NULL,     4,   0),
        (39,  'cross', 'teleport',true,  NULL,     1,   0),
        (42,  'use',   'ceiling', false, NULL,     2,   0),
        (46,  'shoot', 'ceiling', false, NULL,     2,   0),
        (50,  'use',   'ceiling', true,  NULL,     2,   0),
        (51,  'use',   'secret',  true,  NULL,     1,   0),
        (52,  'cross', 'normal',  true,  NULL,     1,   0),
        (61,  'use',   'ceiling', false, NULL,     2,   0),
        (62,  'use',   'floor',   false, NULL,     4, 105),
        (63,  'use',   'ceiling', false, NULL,     2, 150),
        (70,  'use',   'floor',   false, NULL,     4,   0),
        (75,  'cross', 'ceiling', false, NULL,     2,   0),
        (76,  'cross', 'ceiling', false, NULL,     2, 1050),
        (82,  'cross', 'floor',   false, NULL,     1,   0),
        (86,  'cross', 'ceiling', false, NULL,     2,   0),
        (88,  'cross', 'floor',   false, NULL,     4, 105),
        (90,  'cross', 'ceiling', false, NULL,     2, 150),
        (91,  'cross', 'floor',   false, NULL,     1,   0),
        (97,  'cross', 'teleport',false, NULL,     1,   0),
        (98,  'cross', 'floor',   false, NULL,     4,   0),
        (103, 'use',   'ceiling', true,  NULL,     2,   0),
        (117, 'use',   'ceiling', false, NULL,     8, 150),
        (118, 'use',   'ceiling', true,  NULL,     8,   0),
        (124, 'cross', 'secret',  true,  NULL,     1,   0)
    ) AS rule(special, activation, effect, once_only, key_kind, units_per_tick, delay_ticks)
      ON rule.special = raw.special
    WHERE raw.level_id = p_level_id
    ON CONFLICT (level_id, line_id) DO NOTHING;

    WITH RECURSIVE scoped AS MATERIALIZED (
        SELECT action.level_id, action.line_id, action.effect, action.delay_ticks,
               raw.special, raw.tag, line.back_sector_id
        FROM doom.line_actions AS action
        JOIN doom.wad_line_actions AS raw USING (level_id, line_id)
        JOIN doom.lines AS line USING (level_id, line_id)
        WHERE action.level_id = p_level_id AND action.effect IN ('ceiling', 'floor')
    ), candidates AS MATERIALIZED (
        SELECT action.*, target.sector_id, target.floor_height, target.ceiling_height, target.floor_material
        FROM scoped AS action
        JOIN LATERAL (
            SELECT sector.* FROM doom.sectors AS sector
            WHERE action.special IN (1, 26, 27, 28, 31, 32, 33, 34, 117, 118)
              AND sector.level_id = action.level_id AND sector.sector_id = action.back_sector_id
            UNION ALL
            SELECT sector.* FROM doom.wad_sector_properties AS tagged
            JOIN doom.sectors AS sector USING (level_id, sector_id)
            WHERE action.special NOT IN (1, 26, 27, 28, 31, 32, 33, 34, 117, 118)
              AND tagged.level_id = action.level_id AND tagged.tag = action.tag AND tagged.tag <> 0
        ) AS target ON true
    ), neighbors AS MATERIALIZED (
        SELECT edge.line_id, edge.front_sector_id AS origin, edge.back_sector_id AS sector_id,
               sector.floor_height, sector.ceiling_height, sector.floor_material
        FROM doom.lines AS edge
        JOIN doom.sectors AS sector ON sector.level_id = edge.level_id AND sector.sector_id = edge.back_sector_id
        WHERE edge.level_id = p_level_id AND edge.front_sector_id <> edge.back_sector_id
        UNION ALL
        SELECT edge.line_id, edge.back_sector_id, edge.front_sector_id,
               sector.floor_height, sector.ceiling_height, sector.floor_material
        FROM doom.lines AS edge
        JOIN doom.sectors AS sector ON sector.level_id = edge.level_id AND sector.sector_id = edge.front_sector_id
        WHERE edge.level_id = p_level_id AND edge.front_sector_id <> edge.back_sector_id
    ), stairs (line_id, sector_id, height, visited, material) AS (
        SELECT line_id, sector_id, floor_height + 8, ARRAY[sector_id], floor_material
        FROM candidates WHERE special IN (7, 8)
        UNION ALL
        SELECT stairs.line_id, next.sector_id, stairs.height + 8, stairs.visited || next.sector_id, stairs.material
        FROM stairs
        CROSS JOIN LATERAL (
            SELECT edge.back_sector_id AS sector_id
            FROM doom.lines AS edge
            JOIN doom.sectors AS sector ON sector.level_id = edge.level_id AND sector.sector_id = edge.back_sector_id
            WHERE edge.level_id = p_level_id AND edge.front_sector_id = stairs.sector_id
              AND sector.floor_material IS NOT DISTINCT FROM stairs.material
              AND sector.sector_id <> ALL(stairs.visited)
            ORDER BY edge.line_id LIMIT 1
        ) AS next
    ), raised AS (
        SELECT candidate.line_id, candidate.sector_id,
               CASE
                   WHEN candidate.special IN (3, 16, 42, 50, 75, 76) THEN candidate.floor_height
                   WHEN candidate.effect = 'ceiling' THEN greatest(candidate.ceiling_height, around.ceiling_height - 4)
                   WHEN candidate.special IN (5, 91) THEN greatest(candidate.floor_height,
                       least(candidate.ceiling_height, around.ceiling_height))
                   WHEN candidate.special IN (18, 20, 22) THEN least(candidate.ceiling_height, around.next_floor)
                   WHEN candidate.special IN (36, 70, 98) THEN least(candidate.floor_height, around.highest_floor + 8)
                   ELSE least(candidate.floor_height, around.lowest_floor)
               END AS height,
               CASE WHEN candidate.delay_ticks = 0 THEN NULL
                    WHEN candidate.special IN (16, 76) OR candidate.effect = 'floor'
                        THEN CASE WHEN candidate.effect = 'floor' THEN candidate.floor_height ELSE candidate.ceiling_height END
                    ELSE candidate.floor_height END AS return_height
        FROM candidates AS candidate
        CROSS JOIN LATERAL (
            SELECT min(floor_height) AS lowest_floor, max(floor_height) AS highest_floor,
                   min(floor_height) FILTER (WHERE floor_height > candidate.floor_height) AS next_floor,
                   min(ceiling_height) AS ceiling_height
            FROM neighbors WHERE origin = candidate.sector_id
        ) AS around
        WHERE candidate.special NOT IN (7, 8, 9)
    ), rings AS (
        SELECT candidate.line_id, candidate.sector_id, ring.sector_id AS ring_id, outside.floor_height
        FROM candidates AS candidate
        CROSS JOIN LATERAL (
            SELECT sector_id FROM neighbors WHERE origin = candidate.sector_id ORDER BY line_id LIMIT 1
        ) AS ring
        CROSS JOIN LATERAL (
            SELECT floor_height FROM neighbors WHERE origin = ring.sector_id AND sector_id <> candidate.sector_id
            ORDER BY line_id LIMIT 1
        ) AS outside
        WHERE candidate.special = 9
    ), targets AS (
        SELECT * FROM raised
        UNION ALL SELECT line_id, sector_id, height, NULL FROM stairs
        UNION ALL SELECT line_id, sector_id, floor_height, NULL FROM rings
        UNION ALL SELECT line_id, ring_id, floor_height, NULL FROM rings
    )
    INSERT INTO doom.line_action_targets (level_id, line_id, sector_id, height, return_height)
    SELECT DISTINCT ON (target.line_id, target.sector_id) p_level_id, target.line_id, target.sector_id,
           target.height, target.return_height
    FROM targets AS target
    WHERE target.height IS NOT NULL
    ORDER BY target.line_id, target.sector_id, target.height
    ON CONFLICT (level_id, line_id, sector_id) DO NOTHING;

    DELETE FROM doom.line_actions AS action
    WHERE action.level_id = p_level_id AND action.effect IN ('ceiling', 'floor')
      AND NOT EXISTS (SELECT FROM doom.line_action_targets AS target
                      WHERE (target.level_id, target.line_id) = (action.level_id, action.line_id));
END;
$$;

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
    event doom._line_event := ROW(p_player, NULL);
    destination record;
BEGIN
    SELECT * INTO action FROM doom.line_actions
    WHERE level_id = p_player.level_id AND line_id = p_line_id;
    IF NOT FOUND OR (action.key_kind IS NOT NULL AND NOT EXISTS (
        SELECT FROM doom.game_inventory AS key
        WHERE key.game_id = p_player.game_id AND key.item = 'key-' || action.key_kind
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
            INSERT INTO doom.sector_motions (game_id, level_id, sector_id, plane, target_height,
                                              units_per_tick, return_height, delay_ticks)
            SELECT p_player.game_id, target.level_id, target.sector_id, 'ceiling', target.height,
                   action.units_per_tick, target.return_height, action.delay_ticks
            FROM doom.line_action_targets AS target
            WHERE target.level_id = action.level_id AND target.line_id = action.line_id
            ORDER BY target.sector_id
            ON CONFLICT (game_id, sector_id, plane) DO NOTHING;
        WHEN 'floor' THEN
            INSERT INTO doom.sector_motions (game_id, level_id, sector_id, plane, target_height,
                                            units_per_tick, return_height, delay_ticks)
            SELECT p_player.game_id, target.level_id, target.sector_id, 'floor', target.height,
                   action.units_per_tick, target.return_height, action.delay_ticks
            FROM doom.line_action_targets AS target
            WHERE target.level_id = action.level_id AND target.line_id = action.line_id
            ORDER BY target.sector_id
            ON CONFLICT (game_id, sector_id, plane) DO NOTHING;
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
    event doom._line_event := ROW(p_after, NULL);
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
        EXIT WHEN event.exit_kind IS NOT NULL
            OR (p_after.x, p_after.y) IS DISTINCT FROM ((event.player).x, (event.player).y);
    END LOOP;
    RETURN event;
END;
$$;

CREATE FUNCTION doom._advance_motions(p_game bigint, p_tic bigint)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    motion doom.sector_motions;
    current_floor integer;
    current_ceiling integer;
    current_height integer;
    target integer;
    next_height integer;
BEGIN
    FOR motion IN
        SELECT * FROM doom.sector_motions
        WHERE game_id = p_game AND resume_at_tick <= p_tic
        ORDER BY sector_id, plane
    LOOP
        SELECT coalesce(state.floor_height, base.floor_height),
               coalesce(state.ceiling_height, base.ceiling_height)
        INTO STRICT current_floor, current_ceiling
        FROM doom.sectors AS base
        LEFT JOIN doom.sector_state AS state ON state.game_id = p_game AND state.sector_id = base.sector_id
        WHERE base.level_id = motion.level_id AND base.sector_id = motion.sector_id;

        IF motion.plane = 'ceiling' THEN
            current_height := current_ceiling;
            target := greatest(current_floor, motion.target_height);
        ELSE
            current_height := current_floor;
            target := least(current_ceiling, motion.target_height);
        END IF;
        next_height := greatest(current_height::bigint - motion.units_per_tick,
                                least(current_height::bigint + motion.units_per_tick, target));
        IF ((motion.plane = 'ceiling' AND next_height < current_height)
             OR (motion.plane = 'floor' AND next_height > current_height))
            AND EXISTS (
                SELECT FROM doom.actors AS actor
                JOIN doom.thing_types AS kind USING (type_id)
                WHERE actor.game_id = p_game AND actor.sector_id = motion.sector_id
                  AND actor.health > 0 AND kind.blocks_actors
                  AND CASE motion.plane WHEN 'ceiling' THEN actor.z + kind.height > next_height
                      ELSE greatest(next_height, actor.z) + kind.height > current_ceiling END
            )
        THEN
            CONTINUE;
        END IF;

        IF next_height <> current_height THEN
            INSERT INTO doom.sector_state (game_id, level_id, sector_id, floor_height, ceiling_height)
            VALUES (p_game, motion.level_id, motion.sector_id,
                    CASE WHEN motion.plane = 'floor' THEN next_height ELSE current_floor END,
                    CASE WHEN motion.plane = 'ceiling' THEN next_height ELSE current_ceiling END)
            ON CONFLICT (game_id, sector_id) DO UPDATE
            SET floor_height = excluded.floor_height, ceiling_height = excluded.ceiling_height;
            IF motion.plane = 'floor' THEN
                UPDATE doom.actors AS actor SET z = next_height
                WHERE actor.game_id = p_game AND actor.sector_id = motion.sector_id
                  AND (actor.z = current_floor OR actor.z < next_height);
            END IF;
        END IF;

        IF next_height = target THEN
            IF motion.return_height IS NULL THEN
                DELETE FROM doom.sector_motions
                WHERE game_id = p_game AND sector_id = motion.sector_id AND plane = motion.plane;
            ELSE
                UPDATE doom.sector_motions SET target_height = motion.return_height, return_height = NULL,
                    resume_at_tick = p_tic + motion.delay_ticks
                WHERE game_id = p_game AND sector_id = motion.sector_id AND plane = motion.plane;
            END IF;
        END IF;
    END LOOP;
END;
$$;
