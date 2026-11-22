CREATE FUNCTION doom._collect_health(
    p_player doom.actors, p_height double precision, p_radius double precision, p_max_health integer
)
RETURNS integer
LANGUAGE plpgsql STRICT
AS $$
DECLARE
    pickup record;
    reached doom.actors;
    collected_health integer := p_player.health;
BEGIN
    IF collected_health <= 0 OR collected_health >= p_max_health THEN
        RETURN collected_health;
    END IF;

    FOR pickup IN
        SELECT candidate.actor_id, candidate.x, candidate.y, health.amount
        FROM doom.health_pickups AS health
        JOIN doom.actor_types AS kind ON kind.kind = health.kind
        CROSS JOIN LATERAL (SELECT p_radius + kind.radius AS reach) AS contact
        CROSS JOIN LATERAL (
            SELECT actor.actor_id, actor.x, actor.y
            FROM doom.actors AS actor
            WHERE actor.game_id = p_player.game_id AND actor.kind = health.kind AND actor.life_state = 'alive'
              AND actor.sector_id = p_player.sector_id
              AND actor.collision_x_bucket BETWEEN floor(floor(p_player.x - contact.reach) / 64)
                AND floor(floor(p_player.x + contact.reach) / 64)
              AND actor.x BETWEEN p_player.x - contact.reach AND p_player.x + contact.reach
              AND actor.y BETWEEN p_player.y - contact.reach AND p_player.y + contact.reach
              AND actor.z < p_player.z + p_height AND actor.z + kind.height > p_player.z
              AND (point(actor.x, actor.y) <-> point(p_player.x, p_player.y)) <= contact.reach
            FOR UPDATE OF actor SKIP LOCKED
        ) AS candidate
        ORDER BY candidate.actor_id
    LOOP
        -- A solid boundary can separate touching actors in the same sector.
        reached := doom.move_actor(p_player, pickup.x - p_player.x, pickup.y - p_player.y, p_height, 0);
        IF reached.sector_id = p_player.sector_id
            AND abs(reached.x - pickup.x) < 0.000001 AND abs(reached.y - pickup.y) < 0.000001
        THEN
            DELETE FROM doom.actors WHERE game_id = p_player.game_id AND actor_id = pickup.actor_id;
            IF FOUND THEN
                collected_health := least(p_max_health, collected_health::bigint + pickup.amount);
                EXIT WHEN collected_health = p_max_health;
            END IF;
        END IF;
    END LOOP;

    IF collected_health <> p_player.health THEN
        UPDATE doom.actors SET health = collected_health
        WHERE game_id = p_player.game_id AND actor_id = p_player.actor_id;
    END IF;
    RETURN collected_health;
END;
$$;
