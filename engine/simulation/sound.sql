CREATE TABLE doom.sound_events (
    game bigint REFERENCES doom.games ON DELETE CASCADE,
    slot smallint, epoch bigint NOT NULL, tic bigint NOT NULL, cues jsonb NOT NULL,
    PRIMARY KEY(game,slot)
);

-- keep one batch per tic in a two-second window, even when no client is listening
CREATE FUNCTION doom.monster_sound(gid bigint,generation bigint,n bigint,thing int,event text)
RETURNS void LANGUAGE sql AS $$
    INSERT INTO doom.sound_events AS s VALUES
        (gid,n%70,generation,n,jsonb_build_array(jsonb_build_array(thing,event)))
    ON CONFLICT (game,slot) DO UPDATE SET epoch=excluded.epoch,tic=excluded.tic,
        cues=CASE WHEN (s.epoch,s.tic)=(excluded.epoch,excluded.tic) THEN s.cues||excluded.cues ELSE excluded.cues END;
$$;
