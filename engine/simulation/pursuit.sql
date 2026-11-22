CREATE FUNCTION doom._advance_pursuers(p_player doom.actors, p_tick bigint)
RETURNS doom.actors
LANGUAGE plpgsql STRICT
AS $$
DECLARE
    axis_slop CONSTANT double precision := 0.00000001;
    player_radius double precision;
    action record;
    pursuer doom.actors;
    target doom._shot_contact;
    dx double precision;
    dy double precision;
    distance double precision;
    moved_fraction double precision;
BEGIN
    IF p_player.health <= 0 THEN
        RETURN p_player;
    END IF;

    SELECT radius INTO STRICT player_radius FROM doom.actor_types WHERE kind = p_player.kind;

    FOR action IN
        SELECT candidate.state, pursuit.sight_range, pursuit.move_distance,
               kind.height, kind.radius, kind.attack_range, kind.attack_damage
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
        ) AS candidate
        ORDER BY candidate.actor_id
    LOOP
        pursuer := action.state;
        dx := p_player.x - pursuer.x;
        dy := p_player.y - pursuer.y;
        distance := point(dx, dy) <-> point(0, 0);
        IF distance > action.sight_range + player_radius THEN
            CONTINUE;
        END IF;

        pursuer.angle := atan2(dy, dx);
        target := doom._ray_hit(pursuer, action.sight_range,
                               pursuer.z + least(doom._eye_z(0), action.height * 0.75));
        IF target.actor_id IS DISTINCT FROM p_player.actor_id THEN
            CONTINUE;
        END IF;

        IF action.attack_damage > 0 AND action.attack_range > 0 AND target.distance <= action.attack_range THEN
            p_player.health := doom._damage_actor(p_player.game_id, p_player.actor_id, action.attack_damage, p_tick);
        ELSIF action.move_distance > 0 AND distance > 0 THEN
            moved_fraction := CASE WHEN action.move_distance >= distance THEN 1
                                   ELSE action.move_distance / distance END;
            -- Use the same near-axis tolerance as the ray before scaling subnormal coordinates.
            pursuer := doom.move_actor(
                pursuer,
                CASE WHEN abs(dx) >= axis_slop THEN dx * moved_fraction ELSE 0 END,
                CASE WHEN abs(dy) >= axis_slop THEN dy * moved_fraction ELSE 0 END,
                action.height, action.radius
            );
        END IF;
        UPDATE doom.actors AS actor
        SET x = pursuer.x, y = pursuer.y, z = pursuer.z, angle = pursuer.angle, sector_id = pursuer.sector_id
        WHERE actor.game_id = pursuer.game_id AND actor.actor_id = pursuer.actor_id
          AND (actor.x, actor.y, actor.z, actor.angle, actor.sector_id)
              IS DISTINCT FROM (pursuer.x, pursuer.y, pursuer.z, pursuer.angle, pursuer.sector_id);

        IF p_player.health = 0 THEN
            SELECT * INTO STRICT p_player FROM doom.actors
            WHERE game_id = p_player.game_id AND actor_id = p_player.actor_id;
            EXIT;
        END IF;
    END LOOP;

    RETURN p_player;
END;
$$;
