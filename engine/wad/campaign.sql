CREATE TABLE doom.wad_campaigns (
    campaign_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY
);

CREATE TABLE doom.wad_campaign_levels (
    campaign_id bigint NOT NULL REFERENCES doom.wad_campaigns ON DELETE CASCADE,
    episode integer NOT NULL CHECK (episode BETWEEN 0 AND 9),
    map_number integer NOT NULL CHECK (map_number BETWEEN 1 AND 99),
    level_id bigint NOT NULL UNIQUE REFERENCES doom.levels ON DELETE CASCADE,
    PRIMARY KEY (campaign_id, episode, map_number)
);

CREATE TABLE doom.wad_campaign_games (
    game_id bigint PRIMARY KEY REFERENCES doom.games ON DELETE CASCADE,
    skill integer NOT NULL CHECK (skill BETWEEN 1 AND 5),
    secret_return_level_id bigint REFERENCES doom.wad_campaign_levels (level_id) ON DELETE SET NULL,
    next_game_id bigint UNIQUE REFERENCES doom.games ON DELETE SET NULL
);

CREATE FUNCTION doom.import_wad_campaign(p_wad bytea)
RETURNS bigint
LANGUAGE plpgsql STRICT
AS $$
DECLARE
    imported_campaign bigint;
    imported_level bigint;
    marker record;
BEGIN
    INSERT INTO doom.wad_campaigns DEFAULT VALUES RETURNING campaign_id INTO imported_campaign;

    FOR marker IN
        SELECT name, CASE WHEN left(name, 1) = 'E' THEN substring(name, 2, 1)::integer ELSE 0 END AS episode,
               CASE WHEN left(name, 1) = 'E' THEN right(name, 1)::integer
                    ELSE right(name, 2)::integer END AS map_number
        FROM (
            SELECT DISTINCT upper(entry.name COLLATE "C") AS name
            FROM doom.wad_directory(p_wad) AS entry
        ) AS entries
        WHERE name ~ '^(E[1-9]M[1-9]|MAP(0[1-9]|[1-9][0-9]))$'
        ORDER BY episode, map_number
    LOOP
        imported_level := doom.import_wad_level(p_wad, marker.name);
        PERFORM doom.import_wad_materials(imported_level, p_wad);
        PERFORM doom._bind_wad_actors(imported_level, p_wad);
        PERFORM doom._bind_wad_actions(imported_level);
        PERFORM doom._bind_wad_encounters(imported_level);
        INSERT INTO doom.wad_campaign_levels (campaign_id, episode, map_number, level_id)
        VALUES (imported_campaign, marker.episode, marker.map_number, imported_level);
    END LOOP;

    IF NOT EXISTS (SELECT FROM doom.wad_campaign_levels WHERE campaign_id = imported_campaign) THEN
        RAISE EXCEPTION 'no classic map markers found in the WAD' USING ERRCODE = '22023';
    END IF;
    RETURN imported_campaign;
END;
$$;

CREATE FUNCTION doom.start_wad_campaign(p_campaign_id bigint, p_skill integer DEFAULT 3, p_map_name text DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    start_level bigint;
    new_game bigint;
BEGIN
    SELECT map.level_id INTO start_level
    FROM doom.wad_campaign_levels AS map
    JOIN doom.levels AS level USING (level_id)
    WHERE map.campaign_id = p_campaign_id
      AND (p_map_name IS NULL OR level.name = upper(p_map_name COLLATE "C"))
    ORDER BY map.episode, map.map_number
    LIMIT 1;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'no matching map in campaign %', p_campaign_id USING ERRCODE = '22023';
    END IF;

    new_game := doom.start_game(start_level, p_skill);
    INSERT INTO doom.wad_campaign_games (game_id, skill) VALUES (new_game, p_skill);
    RETURN new_game;
END;
$$;

CREATE FUNCTION doom.advance_wad_campaign(p_game_id bigint)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    previous record;
    normal_level bigint;
    secret_level bigint;
    destination bigint;
    new_game bigint;
BEGIN
    SELECT game.finished_at_tick, game.exit_kind, map.campaign_id, map.episode, map.map_number,
           state.skill, state.secret_return_level_id, state.next_game_id
    INTO previous
    FROM doom.games AS game
    JOIN doom.wad_campaign_games AS state USING (game_id)
    JOIN doom.wad_campaign_levels AS map USING (level_id)
    WHERE game.game_id = p_game_id
    FOR UPDATE OF state;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'game % is not a WAD campaign game', p_game_id USING ERRCODE = '22023';
    END IF;
    IF previous.finished_at_tick IS NULL THEN
        RETURN NULL;
    END IF;
    IF previous.next_game_id IS NOT NULL THEN
        RETURN previous.next_game_id;
    END IF;

    IF previous.secret_return_level_id IS NOT NULL THEN
        normal_level := previous.secret_return_level_id;
    ELSIF (previous.episode = 0 AND previous.map_number <> 30)
        OR (previous.episode <> 0 AND previous.map_number < 8)
    THEN
        SELECT map.level_id INTO normal_level FROM doom.wad_campaign_levels AS map
        WHERE map.campaign_id = previous.campaign_id AND map.episode = previous.episode
          AND map.map_number = previous.map_number + 1;
    END IF;

    IF previous.exit_kind = 'secret' THEN
        SELECT map.level_id INTO secret_level FROM doom.wad_campaign_levels AS map
        WHERE map.campaign_id = previous.campaign_id AND map.episode = previous.episode
          AND map.map_number = CASE WHEN previous.episode <> 0 THEN 9
                                    WHEN previous.map_number = 31 THEN 32 ELSE 31 END
          AND map.map_number <> previous.map_number;
    END IF;

    destination := coalesce(secret_level, normal_level);
    IF destination IS NULL THEN
        RETURN NULL;
    END IF;

    new_game := doom.start_game(destination, previous.skill);
    UPDATE doom.actors AS player SET health = old_player.health
    FROM doom.actors AS old_player
    WHERE player.game_id = new_game AND old_player.game_id = p_game_id
      AND player.kind = 'player' AND old_player.kind = 'player';

    INSERT INTO doom.game_inventory (game_id, item_kind, amount)
    SELECT new_game, item_kind, amount FROM doom.game_inventory WHERE game_id = p_game_id
    ON CONFLICT (game_id, item_kind) DO UPDATE SET amount = excluded.amount;

    INSERT INTO doom.wad_campaign_games (game_id, skill, secret_return_level_id)
    VALUES (new_game, previous.skill, CASE WHEN secret_level IS NOT NULL THEN normal_level END);
    UPDATE doom.wad_campaign_games SET next_game_id = new_game WHERE game_id = p_game_id;
    RETURN new_game;
END;
$$;

CREATE FUNCTION doom.step_wad_campaign(
    p_game_id bigint, p_width integer, p_height integer, p_inputs doom.input_command[]
)
RETURNS TABLE (game_id bigint, campaign_finished boolean, frame bytea)
LANGUAGE plpgsql
AS $$
DECLARE
    next_game bigint;
    map_finished boolean;
BEGIN
    IF NOT EXISTS (SELECT FROM doom.wad_campaign_games AS state WHERE state.game_id = p_game_id) THEN
        RAISE EXCEPTION 'game % is not a WAD campaign game', p_game_id USING ERRCODE = '22023';
    END IF;

    PERFORM doom.tick_inputs(p_game_id, p_inputs);
    SELECT game.finished_at_tick IS NOT NULL INTO STRICT map_finished
    FROM doom.games AS game WHERE game.game_id = p_game_id;
    IF map_finished THEN
        next_game := doom.advance_wad_campaign(p_game_id);
    END IF;

    game_id := coalesce(next_game, p_game_id);
    campaign_finished := map_finished AND next_game IS NULL;
    frame := doom.render_compact(game_id, p_width, p_height);
    RETURN NEXT;
END;
$$;
