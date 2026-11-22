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
    axis_slop CONSTANT double precision := 0.00000001;
    eye_height double precision := doom._eye_z(p_actor.z);
    reach double precision;
    damage integer;
    target doom._shot_contact;
    lower_target doom._shot_contact;
    ray_x double precision;
    ray_y double precision;
    weapon_reach integer;
    weapon_damage integer;
BEGIN
    SELECT attack_range, attack_damage INTO STRICT reach, damage
    FROM doom.actor_types WHERE kind = p_actor.kind;
    IF reach = 0 OR damage = 0 THEN
        RETURN NULL;
    END IF;

    target := doom._ray_hit(p_actor, reach, eye_height);
    IF p_actor.kind = 'player' THEN
        IF target.actor_id IS NULL AND EXISTS (
            SELECT FROM doom.level_actor_bindings
            WHERE level_id = p_actor.level_id AND use_wad_flags
        ) THEN
            lower_target := doom._ray_hit(p_actor, least(reach, 128), p_actor.z + 24);
            IF lower_target.actor_id IS NOT NULL AND lower_target.distance >= axis_slop THEN
                ray_x := cos(p_actor.angle);
                ray_y := sin(p_actor.angle);
                -- Require both heights to clear each portal before accepting the low contact.
                IF EXISTS (
                    SELECT FROM doom._ray_sectors(p_actor,
                        CASE WHEN abs(ray_x) >= axis_slop / lower_target.distance
                             THEN lower_target.distance * ray_x ELSE 0 END,
                        CASE WHEN abs(ray_y) >= axis_slop / lower_target.distance
                             THEN lower_target.distance * ray_y ELSE 0 END,
                        eye_height) AS path
                    WHERE path.end_t = 1 AND NOT path.end_blocked
                ) THEN
                    target := lower_target;
                END IF;
            END IF;
        END IF;
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
