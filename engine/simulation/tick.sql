CREATE FUNCTION doom.start_game(
    p_level_id bigint, p_sector_id integer, p_x double precision, p_y double precision,
    p_angle double precision DEFAULT 0
)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    new_game_id bigint;
BEGIN
    INSERT INTO doom.games (level_id) VALUES (p_level_id) RETURNING game_id INTO new_game_id;
    INSERT INTO doom.actors (game_id, sector_id, kind, x, y, angle)
    VALUES (new_game_id, p_sector_id, 'player', p_x, p_y, p_angle);
    RETURN new_game_id;
END;
$$;

CREATE FUNCTION doom.tick(
    p_game_id bigint, p_forward double precision DEFAULT 0, p_strafe double precision DEFAULT 0,
    p_turn double precision DEFAULT 0, p_ticks integer DEFAULT 1
)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    new_tick bigint;
    player doom.actors;
    actor_height double precision;
    actor_radius double precision;
    speed double precision;
    camera_cos double precision;
    camera_sin double precision;
BEGIN
    IF p_ticks IS NULL OR p_ticks NOT BETWEEN 1 AND 128
        OR p_forward IS NULL OR abs(p_forward) > 1
        OR p_strafe IS NULL OR abs(p_strafe) > 1
        OR p_turn IS NULL OR abs(p_turn) > pi()
    THEN
        RAISE EXCEPTION 'invalid input or tick count' USING ERRCODE = '22023';
    END IF;

    UPDATE doom.games SET tick_number = tick_number + p_ticks
    WHERE game_id = p_game_id RETURNING tick_number INTO new_tick;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'game % does not exist', p_game_id USING ERRCODE = '22023';
    END IF;

    IF p_forward = 0 AND p_strafe = 0 AND p_turn = 0 THEN
        RETURN new_tick;
    END IF;

    -- Serialize against edits to the actor before caching its coordinates for the batch.
    SELECT * INTO STRICT player FROM doom.actors
    WHERE game_id = p_game_id AND kind = 'player' FOR NO KEY UPDATE;
    IF player.life_state = 'dead' THEN
        RETURN new_tick;
    END IF;

    IF p_forward <> 0 OR p_strafe <> 0 THEN
        SELECT height, radius INTO STRICT actor_height, actor_radius
        FROM doom.actor_types WHERE kind = player.kind;
        speed := 8 / greatest(1.0, sqrt(p_forward * p_forward + p_strafe * p_strafe));
    END IF;

    FOR tic IN 1..p_ticks LOOP
        player.angle := player.angle + p_turn;
        IF speed IS NOT NULL THEN
            camera_cos := cos(player.angle);
            camera_sin := sin(player.angle);
            player := doom.move_actor(player, speed * (p_forward * camera_cos - p_strafe * camera_sin),
                                      speed * (p_forward * camera_sin + p_strafe * camera_cos),
                                      actor_height, actor_radius);
        END IF;
    END LOOP;

    UPDATE doom.actors AS actor
    SET x = player.x, y = player.y, z = player.z, angle = player.angle, sector_id = player.sector_id
    WHERE actor.game_id = p_game_id AND actor.actor_id = player.actor_id
      AND (actor.x, actor.y, actor.z, actor.angle, actor.sector_id)
          IS DISTINCT FROM (player.x, player.y, player.z, player.angle, player.sector_id);

    RETURN new_tick;
END;
$$;
