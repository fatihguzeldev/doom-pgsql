CREATE TYPE doom.input_command AS (
    forward double precision,
    strafe double precision,
    turn double precision,
    ticks integer,
    use_action boolean,
    fire boolean
);

CREATE FUNCTION doom.tick_inputs(p_game_id bigint, p_inputs doom.input_command[])
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    command doom.input_command;
    pending doom.input_command;
    remaining_ticks integer := 128;
BEGIN
    IF coalesce(array_ndims(p_inputs), 0) <> 1 OR cardinality(p_inputs) > 128 THEN
        RAISE EXCEPTION 'expected a nonempty one-dimensional input array with at most 128 commands'
            USING ERRCODE = '22023';
    END IF;

    FOREACH command IN ARRAY p_inputs LOOP
        IF command.ticks IS NULL OR command.ticks NOT BETWEEN 1 AND remaining_ticks THEN
            RAISE EXCEPTION 'input commands must each have a positive tick count and total at most 128 ticks'
                USING ERRCODE = '22023';
        END IF;
        remaining_ticks := remaining_ticks - command.ticks;

        -- A pressed action belongs to the first tic of its command.
        IF NOT command.use_action AND NOT command.fire
            AND (command.forward, command.strafe, command.turn) = (pending.forward, pending.strafe, pending.turn)
        THEN
            pending.ticks := pending.ticks + command.ticks;
            CONTINUE;
        END IF;

        IF pending.ticks IS NOT NULL THEN
            PERFORM doom.tick(p_game_id, pending.forward, pending.strafe, pending.turn,
                              pending.ticks, pending.use_action, pending.fire);
        END IF;
        pending := command;
    END LOOP;

    RETURN doom.tick(p_game_id, pending.forward, pending.strafe, pending.turn,
                     pending.ticks, pending.use_action, pending.fire);
END;
$$;
