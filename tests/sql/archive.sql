DO $$
DECLARE
    bin bytea := decode('49574144010000000d000000ab0c000000010000007445737400000000','hex');
    entry doom.lump;
BEGIN
    SELECT * INTO STRICT entry FROM doom.directory(bin);
    ASSERT entry.name='TEST' AND entry.pos=12 AND entry.size=1;
    ASSERT doom.s16(decode('00ff','hex'),0)=-256;
    BEGIN
        PERFORM doom.directory(substring(bin FOR 20));
        RAISE EXCEPTION 'truncated directory accepted';
    EXCEPTION WHEN invalid_parameter_value THEN NULL;
    END;
END;
$$;
