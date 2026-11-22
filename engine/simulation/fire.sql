CREATE FUNCTION doom._damage_actor(p_game_id bigint, p_actor_id bigint, p_damage integer, p_tick bigint)
RETURNS integer
LANGUAGE plpgsql STRICT
AS $$
DECLARE
    target_health integer;
    animation_tick bigint;
BEGIN
    UPDATE doom.actors
    SET health = greatest(0, health - p_damage)
    WHERE game_id = p_game_id AND actor_id = p_actor_id AND health > 0
    RETURNING health, animation_start_tick INTO target_health, animation_tick;

    -- The health trigger sees the batch clock. A lethal hit can precede that clock.
    IF target_health = 0 AND animation_tick <> p_tick THEN
        UPDATE doom.actors SET animation_start_tick = p_tick
        WHERE game_id = p_game_id AND actor_id = p_actor_id;
    END IF;

    RETURN target_health;
END;
$$;

CREATE FUNCTION doom._fire_actor(p_actor doom.actors, p_tick bigint)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    reach double precision;
    damage integer;
    target_id bigint;
BEGIN
    SELECT attack_range, attack_damage INTO STRICT reach, damage
    FROM doom.actor_types WHERE kind = p_actor.kind;
    IF reach = 0 OR damage = 0 THEN
        RETURN;
    END IF;

    target_id := doom._ray_target(p_actor, reach, doom._eye_z(p_actor.z));
    IF target_id IS NULL THEN
        RETURN;
    END IF;

    PERFORM doom._damage_actor(p_actor.game_id, target_id, damage, p_tick);
END;
$$;
