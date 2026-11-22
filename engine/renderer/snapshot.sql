CREATE FUNCTION doom.render_snapshot(
    p_game_id bigint, p_width integer, p_height integer, p_columns boolean DEFAULT false
)
RETURNS TABLE (game_id bigint, tick_number bigint, frame bytea)
LANGUAGE plpgsql STABLE PARALLEL SAFE
AS $$
BEGIN
    -- Always delegate validation to the selected renderer, even when no game row exists.
    RETURN QUERY SELECT p_game_id,
        (SELECT game.tick_number FROM doom.games AS game WHERE game.game_id = p_game_id),
        CASE WHEN p_columns THEN doom.render_columns(p_game_id, p_width, p_height)
             ELSE doom.render_compact(p_game_id, p_width, p_height) END;
END;
$$;
