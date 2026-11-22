CREATE TABLE doom.encounter_floor_targets (
    level_id bigint NOT NULL,
    sector_id integer NOT NULL,
    actor_kind text NOT NULL REFERENCES doom.actor_types (kind),
    target_height integer NOT NULL,
    PRIMARY KEY (level_id, sector_id),
    FOREIGN KEY (level_id, sector_id) REFERENCES doom.sectors ON DELETE CASCADE
);

CREATE TABLE doom.cleared_encounters (
    game_id bigint NOT NULL REFERENCES doom.games ON DELETE CASCADE,
    actor_kind text NOT NULL REFERENCES doom.actor_types (kind),
    PRIMARY KEY (game_id, actor_kind)
);

CREATE FUNCTION doom._bind_wad_encounters(p_level_id bigint)
RETURNS void
LANGUAGE sql STRICT
BEGIN ATOMIC
    -- The classic finale convention links a cleared heavy encounter to tagged floors.
    INSERT INTO doom.encounter_floor_targets (level_id, sector_id, actor_kind, target_height)
    SELECT tagged.level_id, tagged.sector_id, binding.kind, min(neighbor.floor_height)
    FROM doom.wad_sector_properties AS tagged
    JOIN doom.sectors AS target USING (level_id, sector_id)
    JOIN doom.level_actor_bindings AS binding ON binding.level_id = tagged.level_id AND binding.type_code = 3003
    JOIN doom.lines AS edge ON edge.level_id = tagged.level_id
         AND tagged.sector_id IN (edge.front_sector_id, edge.back_sector_id)
    JOIN doom.sectors AS neighbor ON neighbor.level_id = tagged.level_id AND neighbor.sector_id =
        CASE WHEN edge.front_sector_id = tagged.sector_id THEN edge.back_sector_id ELSE edge.front_sector_id END
    WHERE tagged.level_id = p_level_id AND tagged.tag = 666
      AND EXISTS (SELECT FROM doom.wad_sector_properties WHERE level_id = p_level_id AND special = 11)
      AND neighbor.floor_height < target.floor_height
    GROUP BY tagged.level_id, tagged.sector_id, binding.kind
    ON CONFLICT (level_id, sector_id) DO NOTHING;
END;

CREATE FUNCTION doom._queue_cleared_encounters(p_game_id bigint, p_level_id bigint)
RETURNS boolean
LANGUAGE plpgsql STRICT
AS $$
BEGIN
    WITH newly_cleared AS (
        INSERT INTO doom.cleared_encounters (game_id, actor_kind)
        SELECT DISTINCT p_game_id, target.actor_kind
        FROM doom.encounter_floor_targets AS target
        WHERE target.level_id = p_level_id
          AND NOT EXISTS (SELECT FROM doom.cleared_encounters AS cleared
                          WHERE cleared.game_id = p_game_id AND cleared.actor_kind = target.actor_kind)
          AND EXISTS (SELECT FROM doom.actors AS actor
                      WHERE actor.game_id = p_game_id AND actor.kind = target.actor_kind)
          AND NOT EXISTS (SELECT FROM doom.actors AS actor
                          WHERE actor.game_id = p_game_id AND actor.kind = target.actor_kind
                            AND actor.life_state = 'alive')
        ON CONFLICT (game_id, actor_kind) DO NOTHING
        RETURNING actor_kind
    )
    INSERT INTO doom.floor_motions (game_id, level_id, sector_id, target_height, units_per_tick, delay_ticks)
    SELECT p_game_id, target.level_id, target.sector_id, target.target_height, 1, 0
    FROM doom.encounter_floor_targets AS target JOIN newly_cleared USING (actor_kind)
    WHERE target.level_id = p_level_id
    ON CONFLICT (game_id, sector_id) DO UPDATE SET target_height = excluded.target_height,
        units_per_tick = excluded.units_per_tick, delay_ticks = 0, return_height = NULL, resume_at_tick = 0;

    RETURN FOUND;
END;
$$;
