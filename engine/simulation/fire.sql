CREATE FUNCTION doom._fire_actor(p_actor doom.actors, p_tick bigint)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    reach double precision;
    damage integer;
    target_id bigint;
    target_health integer;
    animation_tick bigint;
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

    UPDATE doom.actors
    SET health = greatest(0, health - damage)
    WHERE game_id = p_actor.game_id AND actor_id = target_id AND health > 0
    RETURNING health, animation_start_tick INTO target_health, animation_tick;

    -- The health trigger sees the batch clock. A lethal hit can precede that clock.
    IF target_health = 0 AND animation_tick <> p_tick THEN
        UPDATE doom.actors SET animation_start_tick = p_tick
        WHERE game_id = p_actor.game_id AND actor_id = target_id;
    END IF;
END;
$$;
