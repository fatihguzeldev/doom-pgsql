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
    has_floor_motion boolean;
    has_pursuers boolean;
    has_pickups boolean;
    has_wad_items boolean;
    has_cross_actions boolean;
    has_sector_effects boolean;
    has_encounters boolean;
    exit_sectors integer[];
    at_exit boolean;
    current_tick bigint;
    pending_exit text;
    before_move doom.actors;
    line_event doom._line_event;
    line_id integer;
    shot_reach double precision;
    sector_effect record;
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
           EXISTS (SELECT FROM doom.floor_motions WHERE game_id = p_game_id),
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
           EXISTS (
               SELECT FROM doom.wad_item_pickups AS pickup
               CROSS JOIN LATERAL (
                   SELECT FROM doom.actors AS actor
                   WHERE actor.game_id = p_game_id AND actor.kind = pickup.kind AND actor.life_state = 'alive'
                   ORDER BY actor.collision_x_bucket
                   LIMIT 1
               ) AS available
           ),
           (p_forward <> 0 OR p_strafe <> 0) AND EXISTS (
               SELECT FROM doom.line_actions AS action WHERE action.level_id = game_level_id AND action.activation = 'cross'
           ),
           EXISTS (SELECT FROM doom.wad_sector_properties AS sector
                   WHERE sector.level_id = game_level_id AND sector.special IN (4, 5, 7, 11, 16)),
           EXISTS (SELECT FROM doom.encounter_floor_targets AS target WHERE target.level_id = game_level_id),
           (SELECT array_agg(destination.sector_id) FROM doom.level_exits AS destination
            WHERE destination.level_id = game_level_id)
    INTO has_motion, has_floor_motion, has_pursuers, has_pickups, has_wad_items,
         has_cross_actions, has_sector_effects, has_encounters, exit_sectors;
    IF NOT controls_player AND NOT p_use AND NOT p_fire AND NOT has_motion
        AND NOT has_floor_motion AND NOT has_pursuers AND NOT has_pickups AND NOT has_wad_items
        AND NOT has_sector_effects AND NOT has_encounters AND exit_sectors IS NULL
    THEN
        RETURN new_tick;
    END IF;

    IF controls_player OR p_use OR p_fire OR has_pursuers OR has_pickups OR has_wad_items
        OR has_sector_effects OR has_floor_motion OR has_encounters OR exit_sectors IS NOT NULL THEN
        -- Serialize against edits to the actor before caching its coordinates for the batch.
        SELECT * INTO STRICT player FROM doom.actors
        WHERE game_id = p_game_id AND kind = 'player' FOR NO KEY UPDATE;
        IF player.life_state = 'dead' THEN
            controls_player := false;
            has_pursuers := false;
            has_pickups := false;
            has_wad_items := false;
            has_sector_effects := false;
        END IF;
    END IF;

    IF controls_player AND (p_forward <> 0 OR p_strafe <> 0) THEN
        speed := 8 / greatest(1.0, sqrt(p_forward * p_forward + p_strafe * p_strafe));
    END IF;
    IF speed IS NOT NULL OR has_pickups OR has_wad_items THEN
        SELECT height, radius, default_health INTO STRICT actor_height, actor_radius, max_health
        FROM doom.actor_types WHERE kind = player.kind;
    END IF;

    FOR tic IN 1..p_ticks LOOP
        current_tick := new_tick - p_ticks + tic;
        pending_exit := NULL;
        IF controls_player THEN
            player.angle := player.angle + p_turn;
        END IF;
        IF tic = 1 AND p_use AND player.life_state = 'alive' THEN
            SELECT hit.line_id INTO line_id FROM doom._ray_line_action(player, 'use', 64) AS hit;
            IF FOUND THEN
                line_event := doom._activate_line_action(player, line_id);
                has_motion := has_motion OR line_event.ceiling_motion;
                has_floor_motion := has_floor_motion OR line_event.floor_motion;
                pending_exit := line_event.exit_kind;
            ELSE
                has_motion := doom._use_gate(player) OR has_motion;
            END IF;
        END IF;
        IF has_motion THEN
            has_motion := doom._advance_gates(p_game_id, player, current_tick);
        END IF;
        IF tic = 1 AND p_fire AND player.life_state = 'alive' AND pending_exit IS NULL THEN
            shot_reach := doom._fire_actor(player, current_tick);
            IF shot_reach > 0 THEN
                SELECT hit.line_id INTO line_id FROM doom._ray_line_action(player, 'shoot', shot_reach) AS hit;
                IF FOUND THEN
                    line_event := doom._activate_line_action(player, line_id);
                    has_motion := has_motion OR line_event.ceiling_motion;
                    has_floor_motion := has_floor_motion OR line_event.floor_motion;
                    pending_exit := line_event.exit_kind;
                END IF;
            END IF;
        END IF;
        IF tic = 1 AND has_encounters AND doom._queue_cleared_encounters(p_game_id, game_level_id) THEN
            has_floor_motion := true;
        END IF;
        IF has_floor_motion THEN
            has_floor_motion := doom._advance_floors(p_game_id, current_tick);
            SELECT actor.z INTO player.z FROM doom.actors AS actor
            WHERE actor.game_id = p_game_id AND actor.actor_id = player.actor_id;
        END IF;
        IF speed IS NOT NULL AND pending_exit IS NULL THEN
            IF has_cross_actions THEN
                before_move := player;
            END IF;
            camera_cos := cos(player.angle);
            camera_sin := sin(player.angle);
            player := doom.move_actor(player, speed * (p_forward * camera_cos - p_strafe * camera_sin),
                                      speed * (p_forward * camera_sin + p_strafe * camera_cos),
                                      actor_height, actor_radius);
            IF has_cross_actions THEN
                line_event := doom._cross_line_actions(before_move, player);
                player := line_event.player;
                has_motion := has_motion OR line_event.ceiling_motion;
                has_floor_motion := has_floor_motion OR line_event.floor_motion;
                pending_exit := line_event.exit_kind;
            END IF;
        END IF;
        IF has_pickups AND player.health < max_health THEN
            player.health := doom._collect_health(player, actor_height, actor_radius, max_health);
        END IF;
        IF has_wad_items THEN
            PERFORM doom._collect_wad_items(player, actor_height, actor_radius);
        END IF;
        IF has_sector_effects AND player.health > 0 AND (current_tick % 32 = 0 OR player.health <= 10) THEN
            SELECT * INTO sector_effect FROM doom._wad_sector_health(player, current_tick);
            player.health := sector_effect.health;
            IF sector_effect.exits THEN
                pending_exit := coalesce(pending_exit, 'normal');
            END IF;
        END IF;
        at_exit := player.health > 0 AND (pending_exit IS NOT NULL
            OR (exit_sectors IS NOT NULL AND player.sector_id = ANY (exit_sectors)));
        -- Write the pose before other actors use it or the batch returns.
        IF controls_player AND (has_pursuers OR at_exit OR has_floor_motion OR player.health <= 0 OR tic = p_ticks) THEN
            UPDATE doom.actors AS actor
            SET x = player.x, y = player.y, z = player.z, angle = player.angle, sector_id = player.sector_id
            WHERE actor.game_id = p_game_id AND actor.actor_id = player.actor_id
              AND (actor.x, actor.y, actor.z, actor.angle, actor.sector_id)
                  IS DISTINCT FROM (player.x, player.y, player.z, player.angle, player.sector_id);
        END IF;
        IF has_pursuers THEN
            player := doom._advance_pursuers(player, current_tick);
        END IF;
        IF player.health <= 0 THEN
            controls_player := false;
            has_pursuers := false;
            has_pickups := false;
            has_wad_items := false;
            has_sector_effects := false;
            speed := NULL;
        END IF;
        IF at_exit AND player.health > 0 THEN
            UPDATE doom.games SET tick_number = current_tick, finished_at_tick = current_tick, exit_kind = pending_exit
            WHERE game_id = p_game_id;
            RETURN current_tick;
        END IF;
        EXIT WHEN NOT controls_player AND NOT has_motion AND NOT has_floor_motion
            AND NOT has_pursuers AND NOT has_sector_effects;
    END LOOP;

    RETURN new_tick;
END;
$$;
