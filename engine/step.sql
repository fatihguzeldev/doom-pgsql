CREATE FUNCTION doom.step(
    p_game_id bigint, p_width integer, p_height integer,
    p_forward double precision DEFAULT 0, p_strafe double precision DEFAULT 0,
    p_turn double precision DEFAULT 0, p_ticks integer DEFAULT 1, p_use boolean DEFAULT false,
    p_fire boolean DEFAULT false
)
RETURNS bytea
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM doom.tick(p_game_id, p_forward, p_strafe, p_turn, p_ticks, p_use, p_fire);
    RETURN doom.render(p_game_id, p_width, p_height);
END;
$$;

CREATE FUNCTION doom.step_spans(
    p_game_id bigint, p_width integer, p_height integer,
    p_forward double precision DEFAULT 0, p_strafe double precision DEFAULT 0,
    p_turn double precision DEFAULT 0, p_ticks integer DEFAULT 1, p_use boolean DEFAULT false,
    p_fire boolean DEFAULT false
)
RETURNS bytea
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM doom.tick(p_game_id, p_forward, p_strafe, p_turn, p_ticks, p_use, p_fire);
    RETURN doom.render_spans(p_game_id, p_width, p_height);
END;
$$;

CREATE FUNCTION doom.step_compact(
    p_game_id bigint, p_width integer, p_height integer,
    p_forward double precision DEFAULT 0, p_strafe double precision DEFAULT 0,
    p_turn double precision DEFAULT 0, p_ticks integer DEFAULT 1, p_use boolean DEFAULT false,
    p_fire boolean DEFAULT false
)
RETURNS bytea
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM doom.tick(p_game_id, p_forward, p_strafe, p_turn, p_ticks, p_use, p_fire);
    RETURN doom.render_compact(p_game_id, p_width, p_height);
END;
$$;

CREATE FUNCTION doom.step_inputs(
    p_game_id bigint, p_width integer, p_height integer, p_inputs doom.input_command[]
)
RETURNS bytea
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM doom.tick_inputs(p_game_id, p_inputs);
    RETURN doom.render_compact(p_game_id, p_width, p_height);
END;
$$;
