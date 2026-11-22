CREATE FUNCTION doom._advance_floors(p_game_id bigint, p_tick bigint)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    motion doom.floor_motions;
    has_state boolean;
    motion_pending boolean := false;
    current_floor integer;
    current_ceiling integer;
    target_floor integer;
    next_floor integer;
BEGIN
    FOR motion IN SELECT * FROM doom.floor_motions WHERE game_id = p_game_id ORDER BY sector_id FOR NO KEY UPDATE
    LOOP
        IF motion.resume_at_tick > p_tick THEN
            motion_pending := true;
            CONTINUE;
        END IF;

        SELECT floor_height, ceiling_height INTO current_floor, current_ceiling
        FROM doom.sector_state WHERE game_id = p_game_id AND sector_id = motion.sector_id
        FOR NO KEY UPDATE SKIP LOCKED;
        has_state := FOUND;
        IF NOT has_state THEN
            IF EXISTS (SELECT FROM doom.sector_state WHERE game_id = p_game_id AND sector_id = motion.sector_id) THEN
                motion_pending := true;
                CONTINUE;
            END IF;
            SELECT floor_height, ceiling_height INTO STRICT current_floor, current_ceiling
            FROM doom.sectors WHERE level_id = motion.level_id AND sector_id = motion.sector_id;
        END IF;

        target_floor := least(motion.target_height, current_ceiling);
        next_floor := CASE WHEN target_floor > current_floor
            THEN least(target_floor, current_floor::bigint + motion.units_per_tick)
            ELSE greatest(target_floor, current_floor::bigint - motion.units_per_tick)
        END;

        IF next_floor > current_floor AND EXISTS (
            SELECT FROM doom.actors AS actor JOIN doom.actor_types AS kind USING (kind)
            WHERE actor.game_id = p_game_id AND actor.sector_id = motion.sector_id
              AND actor.health > 0 AND kind.blocks_actors
              AND greatest(next_floor::double precision, actor.z) + kind.height > current_ceiling
        ) THEN
            motion_pending := true;
            CONTINUE;
        END IF;

        IF next_floor <> current_floor THEN
            IF NOT has_state AND NOT doom._materialize_gate_state(p_game_id, motion.level_id, motion.sector_id,
                                                                 current_floor, current_ceiling) THEN
                motion_pending := true;
                CONTINUE;
            END IF;
            UPDATE doom.sector_state SET floor_height = next_floor
            WHERE game_id = p_game_id AND sector_id = motion.sector_id;
        END IF;

        IF next_floor <> target_floor THEN
            motion_pending := true;
        ELSIF motion.return_height IS NOT NULL THEN
            UPDATE doom.floor_motions SET target_height = motion.return_height, return_height = NULL,
                                         resume_at_tick = p_tick + motion.delay_ticks
            WHERE game_id = p_game_id AND sector_id = motion.sector_id;
            motion_pending := true;
        ELSE
            DELETE FROM doom.floor_motions WHERE game_id = p_game_id AND sector_id = motion.sector_id;
        END IF;
    END LOOP;
    RETURN motion_pending;
END;
$$;
