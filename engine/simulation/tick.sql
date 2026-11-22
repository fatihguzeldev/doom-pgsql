CREATE FUNCTION doom.start(p_level_id bigint, p_skill integer DEFAULT 3)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    new_game bigint;
    spawn doom.level_things;
    spawn_sector integer;
    spawn_floor integer;
    flag integer;
BEGIN
    IF p_skill IS NULL OR p_skill NOT BETWEEN 1 AND 5 THEN
        RAISE EXCEPTION 'skill must be between 1 and 5' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO spawn
    FROM doom.level_things
    WHERE level_id = p_level_id AND type_code = 1 ORDER BY thing_id LIMIT 1;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'level % has no primary player start', p_level_id USING ERRCODE = '22023';
    END IF;
    spawn_sector := coalesce(spawn.sector_id, doom.sector_at(p_level_id, spawn.x, spawn.y));
    SELECT floor_height INTO spawn_floor FROM doom.sectors
    WHERE level_id = p_level_id AND sector_id = spawn_sector;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'level % player start is outside the map', p_level_id USING ERRCODE = '22023';
    END IF;

    INSERT INTO doom.compiled_line_actions VALUES (p_level_id) ON CONFLICT DO NOTHING;
    IF FOUND THEN
        PERFORM doom._bind_wad_actions(p_level_id);
    END IF;
    INSERT INTO doom.games (level_id, epoch, skill, has_cross_actions)
    VALUES (p_level_id, 1, p_skill, EXISTS (
        SELECT FROM doom.line_actions WHERE level_id = p_level_id AND activation = 'cross'
    ))
    RETURNING game_id INTO new_game;
    INSERT INTO doom.actors (game_id, level_id, sector_id, type_id, kind, x, y, z, angle, health)
    VALUES (new_game, p_level_id, spawn_sector, 1, 'player', spawn.x, spawn.y, spawn_floor,
            radians(spawn.angle_deg % 360), 100);
    INSERT INTO doom.game_inventory (game_id, item, amount) VALUES (new_game, 'bullets', 50);

    flag := CASE WHEN p_skill <= 2 THEN 1 WHEN p_skill = 3 THEN 2 ELSE 4 END;
    INSERT INTO doom.actors (game_id, level_id, sector_id, type_id, kind, x, y, z, angle, health,
                             sprite_material, think_slot)
    SELECT new_game, p_level_id, sector.sector_id, kind.type_id, kind.kind, thing.x, thing.y,
           sector.floor_height, radians(thing.angle_deg % 360), kind.health, kind.sprite, thing.thing_id % 8
    FROM doom.level_things AS thing
    JOIN doom.thing_types AS kind ON kind.type_id = thing.type_code
    JOIN doom.sectors AS sector ON sector.level_id = thing.level_id
        AND sector.sector_id = coalesce(thing.sector_id, doom.sector_at(p_level_id, thing.x, thing.y))
    WHERE thing.level_id = p_level_id AND thing.type_code <> 1
      AND (thing.flags & 16) = 0 AND (thing.flags & flag) <> 0
    ORDER BY thing.thing_id;

    RETURN new_game;
END;
$$;

CREATE FUNCTION doom.tick(
    p_game_id bigint, p_epoch bigint, p_tic bigint,
    p_forward double precision, p_strafe double precision, p_turn double precision,
    p_use boolean, p_fire boolean
)
RETURNS bigint
LANGUAGE plpgsql
SET jit = off
SET plan_cache_mode = force_generic_plan
AS $$
DECLARE
    session doom.games;
    command doom._sim_input := ROW(p_forward, p_strafe, p_turn, p_use, p_fire);
    player doom.actors;
    before_move doom.actors;
    player_height CONSTANT integer := 56;
    player_radius CONSTANT integer := 16;
    facing_x double precision;
    facing_y double precision;
    distance double precision;
    reach double precision;
    action_line integer;
    event doom._line_event;
    pending_exit text;
    hazard integer;
    attack_ready bigint;
BEGIN
    IF p_game_id IS NULL OR p_epoch IS NULL OR p_tic IS NULL OR p_tic < 1
       OR p_forward IS NULL OR abs(p_forward) > 1
       OR p_strafe IS NULL OR abs(p_strafe) > 1
       OR p_turn IS NULL OR abs(p_turn) > pi()
       OR p_use IS NULL OR p_fire IS NULL THEN
        RAISE EXCEPTION 'invalid tick input' USING ERRCODE = '22023';
    END IF;

    SELECT * INTO session FROM doom.games WHERE game_id = p_game_id FOR NO KEY UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'game % does not exist', p_game_id USING ERRCODE = 'P0002';
    END IF;
    IF p_epoch <> session.epoch THEN
        RAISE EXCEPTION 'incorrect epoch for game %', p_game_id USING ERRCODE = '22023';
    END IF;
    IF p_tic = session.tick_number AND command IS DISTINCT FROM session.last_input THEN
        RAISE EXCEPTION 'conflicting input for committed tic %', p_tic USING ERRCODE = '22023';
    END IF;
    IF p_tic <= session.tick_number OR session.finished_at_tick IS NOT NULL THEN
        RETURN session.tick_number;
    END IF;
    IF p_tic <> session.tick_number + 1 THEN
        RAISE EXCEPTION 'expected tic %, received %', session.tick_number + 1, p_tic USING ERRCODE = '22023';
    END IF;

    -- Plane movement updates grounded actors first, including an idle player.
    PERFORM doom._advance_motions(p_game_id, p_tic);
    SELECT * INTO STRICT player FROM doom.actors WHERE game_id = p_game_id AND kind = 'player';
    attack_ready := session.next_attack;
    IF player.health > 0 THEN
        IF p_turn <> 0 THEN
            player.angle := player.angle + p_turn;
            player.angle := player.angle - floor(player.angle / (2 * pi())) * (2 * pi());
        END IF;
        IF p_use THEN
            SELECT line_id INTO action_line FROM doom._ray_line_action(player, 'use', 64);
            IF FOUND THEN
                event := doom._activate_line_action(player, action_line);
                player := event.player;
                pending_exit := event.exit_kind;
            END IF;
        END IF;

        IF pending_exit IS NULL AND p_fire AND p_tic >= attack_ready THEN
            reach := doom._player_shot(player, p_tic);
            attack_ready := p_tic + 8;
            SELECT line_id INTO action_line FROM doom._ray_line_action(player, 'shoot', reach);
            IF FOUND THEN
                event := doom._activate_line_action(player, action_line);
                pending_exit := event.exit_kind;
            END IF;
        END IF;

        IF pending_exit IS NULL AND (p_forward <> 0 OR p_strafe <> 0) THEN
            facing_x := cos(player.angle);
            facing_y := sin(player.angle);
            distance := 8 / greatest(1, sqrt(p_forward * p_forward + p_strafe * p_strafe));
            before_move := player;
            player := doom._move_actor(player, distance * (p_forward * facing_x - p_strafe * facing_y),
                distance * (p_forward * facing_y + p_strafe * facing_x),
                player_height, player_radius);
            IF session.has_cross_actions THEN
                event := doom._cross_line_actions(before_move, player);
                player := event.player;
                pending_exit := event.exit_kind;
            END IF;
        END IF;

        IF pending_exit IS NULL THEN
            player := doom._collect_items(player, player_height, player_radius);
            IF p_tic % 32 = 0 THEN
                SELECT special INTO hazard FROM doom.sectors
                WHERE level_id = session.level_id AND sector_id = player.sector_id;
                IF hazard IN (4, 5, 7, 11, 16)
                    AND doom._spend_inventory(p_game_id, 'hazard-protection', 1) = 0 THEN
                    player.health := greatest(0, player.health - CASE hazard
                        WHEN 5 THEN 10 WHEN 7 THEN 5 ELSE 20 END);
                    IF hazard = 11 AND player.health <= 10 THEN
                        pending_exit := 'normal';
                    END IF;
                END IF;
            END IF;
        END IF;

        UPDATE doom.actors AS actor
        SET x = player.x, y = player.y, z = player.z, angle = player.angle,
            health = player.health, sector_id = player.sector_id,
            animation_start_tick = CASE WHEN player.health = 0 THEN p_tic ELSE actor.animation_start_tick END
        WHERE actor.game_id = p_game_id AND actor.actor_id = player.actor_id
          AND (actor.x, actor.y, actor.z, actor.angle, actor.health, actor.sector_id) IS DISTINCT FROM
               (player.x, player.y, player.z, player.angle, player.health, player.sector_id);

        IF player.health > 0 AND pending_exit IS NULL THEN
            PERFORM doom._monster_turns(player, p_tic);
        END IF;
    END IF;

    UPDATE doom.games
    SET tick_number = p_tic, last_input = command, next_attack = attack_ready,
        finished_at_tick = CASE WHEN pending_exit IS NOT NULL THEN p_tic END,
        exit_kind = pending_exit
    WHERE game_id = p_game_id;
    RETURN p_tic;
END;
$$;
