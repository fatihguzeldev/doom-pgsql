CREATE FUNCTION doom.start_game(p_level_id bigint)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    spawn record;
BEGIN
    SELECT thing.x, thing.y, thing.angle_deg INTO spawn
    FROM doom.level_things AS thing
    WHERE thing.level_id = p_level_id AND thing.type_code = 1
    ORDER BY thing.thing_id
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'level % has no primary player start', p_level_id USING ERRCODE = '22023';
    END IF;

    RETURN doom.start_game(p_level_id, NULL, spawn.x, spawn.y, radians(spawn.angle_deg));
END;
$$;
