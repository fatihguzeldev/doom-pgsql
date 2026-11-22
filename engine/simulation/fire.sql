CREATE FUNCTION doom._damage_actor(p_game_id bigint, p_actor_id bigint, p_damage integer, p_tick bigint)
RETURNS integer
LANGUAGE plpgsql STRICT
AS $$
DECLARE
    target_health integer;
    animation_tick bigint;
BEGIN
    IF p_damage >= 3 AND EXISTS (
        SELECT FROM doom.game_inventory WHERE game_id = p_game_id AND item_kind = 'armor'
    ) THEN
        PERFORM 1 FROM doom.actors
        WHERE game_id = p_game_id AND actor_id = p_actor_id AND kind = 'player' AND health > 0
        FOR NO KEY UPDATE;
        IF FOUND THEN
            p_damage := p_damage - doom._consume_inventory(p_game_id, 'armor', p_damage / 3, true);
        END IF;
    END IF;

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
RETURNS double precision
LANGUAGE plpgsql
AS $$
DECLARE
    reach double precision;
    damage integer;
    target doom._shot_contact;
    weapon_reach integer;
    weapon_damage integer;
BEGIN
    SELECT attack_range, attack_damage INTO STRICT reach, damage
    FROM doom.actor_types WHERE kind = p_actor.kind;
    IF reach = 0 OR damage = 0 THEN
        RETURN NULL;
    END IF;

    target := doom._ray_hit(p_actor, reach, doom._eye_z(p_actor.z));
    IF p_actor.kind = 'player' THEN
        SELECT attack.reach, attack.damage INTO weapon_reach, weapon_damage
        FROM doom._wad_weapon_attack(p_actor.game_id, target.distance) AS attack;
        reach := least(reach, weapon_reach);
        damage := coalesce(weapon_damage, damage);
    END IF;

    IF target.actor_id IS NOT NULL THEN
        PERFORM doom._damage_actor(p_actor.game_id, target.actor_id, damage, p_tick);
        RETURN least(reach, target.distance);
    END IF;
    RETURN reach;
END;
$$;
