CREATE FUNCTION doom.start_game(p_level_id bigint)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    spawn record;
    new_game_id bigint;
BEGIN
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
    ORDER BY thing.thing_id;

    RETURN new_game_id;
END;
$$;
