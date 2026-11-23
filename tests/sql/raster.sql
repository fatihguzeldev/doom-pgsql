DO $$
DECLARE
    data bytea:=decode('0001020304050607','hex');
    v float8; step float8; n int; expected bytea;
BEGIN
    FOREACH v IN ARRAY ARRAY[-0.25,0,1,1.05,3.85]::float8[] LOOP
        FOREACH step IN ARRAY ARRAY[0,0.5,0.98,1,1.02,2.75]::float8[] LOOP
            FOR n IN 1..11 LOOP
                SELECT string_agg(substring(data FROM 5+(floor(v+i*step)::int & 3) FOR 1),''::bytea ORDER BY i)
                INTO expected FROM generate_series(0,n-1)i;
                ASSERT doom.column_samples(data,2,4,1,v,step,n)=expected;
            END LOOP;
        END LOOP;
    END LOOP;
END;
$$;
