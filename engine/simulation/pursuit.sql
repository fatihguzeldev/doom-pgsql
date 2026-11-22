CREATE TYPE doom._pursuit_action AS (
    actor doom.actors,
    sight_range integer,
    move_distance integer,
    height double precision,
    radius double precision,
    attack_range integer,
    attack_damage integer
);

CREATE TYPE doom._pursuit_batch AS (
    next_action integer,
    damage integer,
    poses doom.actors[]
);

-- A STABLE statement keeps cached bodies and every geometry read on the
-- same snapshot, including live portal openings and externally edited walls.
CREATE FUNCTION doom._solve_pursuit(
    p_player doom.actors, p_player_radius double precision,
    p_actions doom._pursuit_action[], p_first_action integer
)
RETURNS doom._pursuit_batch
LANGUAGE plpgsql STABLE STRICT
AS $$
DECLARE
    axis_slop CONSTANT double precision := 0.00000001;
    action doom._pursuit_action;
    pursuer doom.actors;
    target doom._shot_contact;
    dx double precision;
    dy double precision;
    distance double precision;
    moved_fraction double precision;
    bodies doom._sim_body[];
    body_ids bigint[];
    body_index integer;
    body doom._sim_body;
    damage integer := 0;
    changed doom.actors[] := '{}'::doom.actors[];
BEGIN
    SELECT coalesce(array_agg(ROW(actor.actor_id, actor.sector_id, actor.x, actor.y, actor.z,
                   kind.height, kind.radius, kind.blocks_actors, kind.shootable)::doom._sim_body
               ORDER BY actor.actor_id), '{}'::doom._sim_body[]),
           array_agg(actor.actor_id ORDER BY actor.actor_id)
    INTO bodies, body_ids
    FROM doom.actors AS actor
    JOIN doom.actor_types AS kind ON kind.kind = actor.kind
    WHERE actor.game_id = p_player.game_id AND actor.health > 0 AND kind.radius > 0
      AND (kind.blocks_actors OR kind.shootable);

    FOR action_index IN p_first_action..cardinality(p_actions) LOOP
        action := p_actions[action_index];
        pursuer := action.actor;
        dx := p_player.x - pursuer.x;
        dy := p_player.y - pursuer.y;
        distance := point(dx, dy) <-> point(0, 0);
        IF distance > action.sight_range + p_player_radius THEN
            CONTINUE;
        END IF;

        pursuer.angle := atan2(dy, dx);
        target := doom._sim_ray_hit(pursuer, action.sight_range,
                                  pursuer.z + least(doom._eye_z(0), action.height * 0.75), bodies);
        IF target.actor_id IS DISTINCT FROM p_player.actor_id THEN
            CONTINUE;
        END IF;

        IF action.attack_damage > 0 AND action.attack_range > 0 AND target.distance <= action.attack_range THEN
            damage := action.attack_damage;
        ELSIF action.move_distance > 0 AND distance > 0 THEN
            moved_fraction := CASE WHEN action.move_distance >= distance THEN 1
                                   ELSE action.move_distance / distance END;
            -- Use the same near-axis tolerance as the ray before scaling subnormal coordinates.
            pursuer := doom._move_actor(
                pursuer,
                CASE WHEN abs(dx) >= axis_slop THEN dx * moved_fraction ELSE 0 END,
                CASE WHEN abs(dy) >= axis_slop THEN dy * moved_fraction ELSE 0 END,
                action.height, action.radius, bodies
            );
        END IF;
        IF (pursuer.x, pursuer.y, pursuer.z, pursuer.angle, pursuer.sector_id) IS DISTINCT FROM
           ((action.actor).x, (action.actor).y, (action.actor).z, (action.actor).angle, (action.actor).sector_id)
        THEN
            changed := array_append(changed, pursuer);
            body_index := array_position(body_ids, pursuer.actor_id);
            IF body_index IS NOT NULL THEN
                body := bodies[body_index];
                body.sector_id := pursuer.sector_id;
                body.x := pursuer.x;
                body.y := pursuer.y;
                body.z := pursuer.z;
                bodies[body_index] := body;
            END IF;
        END IF;

        IF damage > 0 THEN
            RETURN ROW(action_index + 1, damage, changed)::doom._pursuit_batch;
        END IF;
    END LOOP;

    RETURN ROW(cardinality(p_actions) + 1, 0, changed)::doom._pursuit_batch;
END;
$$;

CREATE FUNCTION doom._advance_pursuers(p_player doom.actors, p_tick bigint)
RETURNS doom.actors
LANGUAGE plpgsql STRICT
AS $$
DECLARE
    player_radius double precision;
    actions doom._pursuit_action[];
    batch doom._pursuit_batch;
    next_action integer := 1;
BEGIN
    IF p_player.health <= 0 THEN
        RETURN p_player;
    END IF;

    SELECT radius INTO STRICT player_radius FROM doom.actor_types WHERE kind = p_player.kind;

    SELECT array_agg(ROW(candidate.state, pursuit.sight_range, pursuit.move_distance,
                   kind.height, kind.radius, kind.attack_range, kind.attack_damage)::doom._pursuit_action
               ORDER BY candidate.actor_id)
    INTO actions
    FROM doom.actor_pursuits AS pursuit
    JOIN doom.actor_types AS kind ON kind.kind = pursuit.kind
    CROSS JOIN LATERAL (
        SELECT actor AS state, actor.actor_id
        FROM doom.actors AS actor
        WHERE actor.game_id = p_player.game_id AND actor.kind = pursuit.kind AND actor.life_state = 'alive'
          AND actor.actor_id % pursuit.interval_ticks = p_tick % pursuit.interval_ticks
          AND actor.collision_x_bucket BETWEEN floor(floor(p_player.x - pursuit.sight_range - player_radius) / 64)
            AND floor(floor(p_player.x + pursuit.sight_range + player_radius) / 64)
          AND actor.x BETWEEN p_player.x - pursuit.sight_range - player_radius
                          AND p_player.x + pursuit.sight_range + player_radius
          AND actor.y BETWEEN p_player.y - pursuit.sight_range - player_radius
                          AND p_player.y + pursuit.sight_range + player_radius
        FOR NO KEY UPDATE OF actor SKIP LOCKED
    ) AS candidate;

    WHILE next_action <= cardinality(actions) LOOP
        batch := doom._solve_pursuit(p_player, player_radius, actions, next_action);
        next_action := batch.next_action;

        IF cardinality(batch.poses) > 0 THEN
            UPDATE doom.actors AS actor
            SET x = pose.x, y = pose.y, z = pose.z, angle = pose.angle, sector_id = pose.sector_id
            FROM unnest(batch.poses) AS pose
            WHERE actor.game_id = pose.game_id AND actor.actor_id = pose.actor_id;
        END IF;

        -- Damage and inventory may require row locks. Publish the poses
        -- resolved so far, then open another coherent pass if needed.
        IF batch.damage > 0 THEN
            p_player.health := doom._damage_actor(p_player.game_id, p_player.actor_id, batch.damage, p_tick);
            IF p_player.health = 0 THEN
                SELECT * INTO STRICT p_player FROM doom.actors
                WHERE game_id = p_player.game_id AND actor_id = p_player.actor_id;
                EXIT;
            END IF;
        END IF;
    END LOOP;
    RETURN p_player;
END;
$$;
