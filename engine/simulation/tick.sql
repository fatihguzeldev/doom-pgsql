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
    p_turn double precision DEFAULT 0, p_ticks integer DEFAULT 1, p_use boolean DEFAULT false,
    p_fire boolean DEFAULT false
)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    new_tick bigint;
    game_level_id bigint;
    player doom.actors;
    controls_player boolean := p_forward <> 0 OR p_strafe <> 0 OR p_turn <> 0;
    has_motion boolean;
    has_pursuers boolean;
    has_pickups boolean;
    exit_sectors integer[];
    at_exit boolean;
    actor_height double precision;
    actor_radius double precision;
    max_health integer;
    speed double precision;
    camera_cos double precision;
    camera_sin double precision;
BEGIN
    IF p_ticks IS NULL OR p_ticks NOT BETWEEN 1 AND 128
        OR p_use IS NULL OR p_fire IS NULL
        OR p_forward IS NULL OR abs(p_forward) > 1
        OR p_strafe IS NULL OR abs(p_strafe) > 1
        OR p_turn IS NULL OR abs(p_turn) > pi()
    THEN
        RAISE EXCEPTION 'invalid input or tick count' USING ERRCODE = '22023';
    END IF;

    UPDATE doom.games AS game SET tick_number = game.tick_number + p_ticks
    WHERE game.game_id = p_game_id AND game.finished_at_tick IS NULL
    RETURNING game.tick_number, game.level_id INTO new_tick, game_level_id;
    IF NOT FOUND THEN
        SELECT game.tick_number INTO new_tick FROM doom.games AS game WHERE game.game_id = p_game_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'game % does not exist', p_game_id USING ERRCODE = '22023';
        END IF;
        RETURN new_tick;
    END IF;

    -- Read activity after taking the game lock so this sees its predecessor's committed state.
    SELECT EXISTS (SELECT FROM doom.ceiling_motions WHERE game_id = p_game_id),
           EXISTS (
               SELECT FROM doom.actor_pursuits AS pursuit
               CROSS JOIN LATERAL (
                   SELECT FROM doom.actors AS actor
                   WHERE actor.game_id = p_game_id AND actor.kind = pursuit.kind AND actor.life_state = 'alive'
                   -- Use the live kind index even when this game has none of the configured actors.
                   ORDER BY actor.collision_x_bucket
                   LIMIT 1
               ) AS living
           ),
           EXISTS (
               SELECT FROM doom.health_pickups AS pickup
               CROSS JOIN LATERAL (
                   SELECT FROM doom.actors AS actor
                   WHERE actor.game_id = p_game_id AND actor.kind = pickup.kind AND actor.life_state = 'alive'
                   ORDER BY actor.collision_x_bucket
                   LIMIT 1
               ) AS available
           ),
           (SELECT array_agg(destination.sector_id) FROM doom.level_exits AS destination
            WHERE destination.level_id = game_level_id)
    INTO has_motion, has_pursuers, has_pickups, exit_sectors;
    IF NOT controls_player AND NOT p_use AND NOT p_fire AND NOT has_motion
        AND NOT has_pursuers AND NOT has_pickups AND exit_sectors IS NULL
    THEN
        RETURN new_tick;
    END IF;

    IF controls_player OR p_use OR p_fire OR has_pursuers OR has_pickups OR exit_sectors IS NOT NULL THEN
        -- Serialize against edits to the actor before caching its coordinates for the batch.
        SELECT * INTO STRICT player FROM doom.actors
        WHERE game_id = p_game_id AND kind = 'player' FOR NO KEY UPDATE;
        IF player.life_state = 'dead' THEN
            controls_player := false;
            has_pursuers := false;
            has_pickups := false;
        END IF;
    END IF;

    IF controls_player AND (p_forward <> 0 OR p_strafe <> 0) THEN
        speed := 8 / greatest(1.0, sqrt(p_forward * p_forward + p_strafe * p_strafe));
    END IF;
    IF speed IS NOT NULL OR has_pickups THEN
        SELECT height, radius, default_health INTO STRICT actor_height, actor_radius, max_health
        FROM doom.actor_types WHERE kind = player.kind;
    END IF;

    FOR tic IN 1..p_ticks LOOP
        IF controls_player THEN
            player.angle := player.angle + p_turn;
        END IF;
        IF tic = 1 AND p_use AND player.life_state = 'alive' THEN
            IF doom._use_gate(player) THEN
                has_motion := true;
            END IF;
        END IF;
        IF has_motion THEN
            has_motion := doom._advance_gates(p_game_id, player);
        END IF;
        IF tic = 1 AND p_fire AND player.life_state = 'alive' THEN
            PERFORM doom._fire_actor(player, new_tick - p_ticks + 1);
        END IF;
        IF speed IS NOT NULL THEN
            camera_cos := cos(player.angle);
            camera_sin := sin(player.angle);
            player := doom.move_actor(player, speed * (p_forward * camera_cos - p_strafe * camera_sin),
                                      speed * (p_forward * camera_sin + p_strafe * camera_cos),
                                      actor_height, actor_radius);
        END IF;
        IF has_pickups AND player.health < max_health THEN
            player.health := doom._collect_health(player, actor_height, actor_radius, max_health);
        END IF;
        at_exit := exit_sectors IS NOT NULL AND player.health > 0 AND player.sector_id = ANY (exit_sectors);
        -- Write the pose before other actors use it or the batch returns.
        IF controls_player AND (has_pursuers OR at_exit OR tic = p_ticks) THEN
            UPDATE doom.actors AS actor
            SET x = player.x, y = player.y, z = player.z, angle = player.angle, sector_id = player.sector_id
            WHERE actor.game_id = p_game_id AND actor.actor_id = player.actor_id
              AND (actor.x, actor.y, actor.z, actor.angle, actor.sector_id)
                  IS DISTINCT FROM (player.x, player.y, player.z, player.angle, player.sector_id);
        END IF;
        IF has_pursuers THEN
            player := doom._advance_pursuers(player, new_tick - p_ticks + tic);
            IF player.health <= 0 THEN
                controls_player := false;
                has_pursuers := false;
                has_pickups := false;
                speed := NULL;
            END IF;
        END IF;
        IF at_exit AND player.health > 0 THEN
            new_tick := new_tick - p_ticks + tic;
            UPDATE doom.games SET tick_number = new_tick, finished_at_tick = new_tick WHERE game_id = p_game_id;
            RETURN new_tick;
        END IF;
        EXIT WHEN NOT controls_player AND NOT has_motion AND NOT has_pursuers;
    END LOOP;

    RETURN new_tick;
END;
$$;
