CREATE FUNCTION doom.step(
    p_game_id bigint, p_width integer, p_height integer,
    p_forward double precision DEFAULT 0, p_strafe double precision DEFAULT 0,
    p_turn double precision DEFAULT 0, p_ticks integer DEFAULT 1, p_use boolean DEFAULT false
)
RETURNS bytea
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM doom.tick(p_game_id, p_forward, p_strafe, p_turn, p_ticks, p_use);
    RETURN doom.render(p_game_id, p_width, p_height);
END;
$$;

CREATE FUNCTION doom.step_spans(
    p_game_id bigint, p_width integer, p_height integer,
    p_forward double precision DEFAULT 0, p_strafe double precision DEFAULT 0,
    p_turn double precision DEFAULT 0, p_ticks integer DEFAULT 1, p_use boolean DEFAULT false
)
RETURNS bytea
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM doom.tick(p_game_id, p_forward, p_strafe, p_turn, p_ticks, p_use);
    RETURN doom.render_spans(p_game_id, p_width, p_height);
END;
$$;
