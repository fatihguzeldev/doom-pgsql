CREATE FUNCTION doom._materialize_gate_state(
    p_game_id bigint, p_level_id bigint, p_sector_id integer, p_floor integer, p_ceiling integer
)
RETURNS boolean
LANGUAGE plpgsql
SET lock_timeout = '1ms'
AS $$
BEGIN
    -- A concurrent floor insert may need the actor lock already held by this tick.
    INSERT INTO doom.sector_state (game_id, level_id, sector_id, floor_height, ceiling_height)
    VALUES (p_game_id, p_level_id, p_sector_id, p_floor, p_ceiling)
    ON CONFLICT (game_id, sector_id) DO NOTHING;
    RETURN FOUND;
EXCEPTION WHEN lock_not_available THEN
    RETURN false;
END;
$$;

CREATE FUNCTION doom._advance_gates(p_game_id bigint, p_player doom.actors DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    motion doom.ceiling_motions;
    has_state boolean;
    motion_pending boolean := false;
    current_floor integer;
    current_ceiling integer;
    target_ceiling integer;
    next_ceiling integer;
    moving_player_id bigint := CASE WHEN p_player.game_id = p_game_id THEN p_player.actor_id END;
BEGIN
    FOR motion IN
        SELECT * FROM doom.ceiling_motions WHERE game_id = p_game_id
        ORDER BY sector_id FOR NO KEY UPDATE
    LOOP
        SELECT floor_height, ceiling_height INTO current_floor, current_ceiling
        FROM doom.sector_state
        WHERE game_id = p_game_id AND sector_id = motion.sector_id
        FOR NO KEY UPDATE SKIP LOCKED;
        has_state := FOUND;
        IF NOT has_state THEN
            -- A floor edit can hold this row while waiting for a grounded actor.
            IF EXISTS (SELECT FROM doom.sector_state WHERE game_id = p_game_id AND sector_id = motion.sector_id) THEN
                motion_pending := true;
                CONTINUE;
            END IF;
            SELECT floor_height, ceiling_height INTO STRICT current_floor, current_ceiling
            FROM doom.sectors WHERE level_id = motion.level_id AND sector_id = motion.sector_id;
        END IF;

        target_ceiling := greatest(motion.target_height, current_floor);
        next_ceiling := CASE WHEN target_ceiling > current_ceiling
            THEN least(target_ceiling, current_ceiling::bigint + motion.units_per_tick)
            ELSE greatest(target_ceiling, current_ceiling::bigint - motion.units_per_tick)
        END;

        IF next_ceiling < current_ceiling AND EXISTS (
            SELECT FROM (
                SELECT actor.kind, actor.z
                FROM doom.actors AS actor
                WHERE actor.game_id = p_game_id AND actor.sector_id = motion.sector_id
                  AND actor.health > 0 AND actor.actor_id IS DISTINCT FROM moving_player_id
                UNION ALL
                SELECT p_player.kind, p_player.z
                WHERE moving_player_id IS NOT NULL AND p_player.sector_id = motion.sector_id AND p_player.health > 0
            ) AS occupant
            JOIN doom.actor_types AS kind ON kind.kind = occupant.kind
            WHERE kind.height > next_ceiling::double precision - occupant.z
        ) THEN
            motion_pending := true;
            CONTINUE;
        END IF;

        IF next_ceiling <> current_ceiling THEN
            IF has_state THEN
                UPDATE doom.sector_state SET ceiling_height = next_ceiling
                WHERE game_id = p_game_id AND sector_id = motion.sector_id;
            ELSIF NOT doom._materialize_gate_state(p_game_id, motion.level_id, motion.sector_id,
                                                   current_floor, next_ceiling) THEN
                motion_pending := true;
                CONTINUE;
            END IF;
        END IF;

        IF next_ceiling = target_ceiling THEN
            DELETE FROM doom.ceiling_motions WHERE game_id = p_game_id AND sector_id = motion.sector_id;
        ELSE
            motion_pending := true;
        END IF;
    END LOOP;

    RETURN motion_pending;
END;
$$;
