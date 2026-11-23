-- call in autocommit mode to publish each tic as it completes.
CREATE PROCEDURE doom.submit(g bigint,generation bigint,first_tic bigint,commands jsonb,INOUT acknowledged bigint DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE
    item jsonb;
    n bigint:=first_tic;
BEGIN
    IF jsonb_typeof(commands) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'expected input array' USING ERRCODE='22023'; END IF;
    FOR item IN SELECT value FROM jsonb_array_elements(commands) LOOP
        IF jsonb_typeof(item)<>'array' OR jsonb_array_length(item)<>5 THEN RAISE EXCEPTION 'expected five input fields' USING ERRCODE='22023'; END IF;
        acknowledged:=doom.tick(g,generation,n,(item->>0)::float8,(item->>1)::float8,(item->>2)::float8,
            (item->>3)::boolean,(item->>4)::boolean);
        COMMIT AND CHAIN;
        EXIT WHEN acknowledged<n;
        n:=n+1;
    END LOOP;
END;
$$;
