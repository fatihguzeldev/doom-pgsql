CREATE FUNCTION doom.start_game(p_level_id bigint, p_skill integer)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    spawn record;
    new_game_id bigint;
BEGIN
    IF p_skill IS NULL OR p_skill NOT BETWEEN 1 AND 5 THEN
        RAISE EXCEPTION 'skill must be between 1 and 5' USING ERRCODE = '22023';
    END IF;

    SELECT thing.x, thing.y, thing.angle_deg INTO spawn
    FROM doom.level_things AS thing
    WHERE thing.level_id = p_level_id AND thing.type_code = 1
    ORDER BY thing.thing_id
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'level % has no primary player start', p_level_id USING ERRCODE = '22023';
    END IF;

    new_game_id := doom.start_game(p_level_id, NULL, spawn.x, spawn.y, radians(spawn.angle_deg));

    INSERT INTO doom.actors (game_id, kind, x, y, angle)
    SELECT new_game_id, binding.kind, thing.x, thing.y, radians(thing.angle_deg)
    FROM doom.level_things AS thing
    JOIN doom.level_actor_bindings AS binding USING (level_id, type_code)
    WHERE thing.level_id = p_level_id
      AND (NOT binding.use_wad_flags OR doom._wad_thing_enabled(thing.flags, p_skill))
    ORDER BY thing.thing_id;

    RETURN new_game_id;
END;
$$;

CREATE FUNCTION doom.start_game(p_level_id bigint)
RETURNS bigint
LANGUAGE sql
RETURN doom.start_game(p_level_id, 3);
