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

DO $$
DECLARE
    data bytea;
    atlas bytea;
    cuts float8[];
    offsets smallint[];
    step float8;
    v float8;
    sample bytea;
    rows bytea[];
    cols bytea[];
BEGIN
    SELECT decode(string_agg(lpad(to_hex(i),2,'0'),'' ORDER BY i),'hex') INTO data FROM generate_series(0,127)i;
    atlas:=doom.wall_quads(data,2,64);
    SELECT w.cuts,w.quads INTO cuts,offsets FROM doom.wall_scales w;
    FOR bucket IN 1..cardinality(offsets)/25 LOOP
        step:=(cuts[bucket]+cuts[bucket+1])/2;
        v:=-11-49.5*step;
        sample:=doom.wall_strip(atlas,16*64,16*((-11)&63),16*64-1,offsets,1+(bucket-1)*25);
        FOR y IN 0..99 LOOP
            ASSERT get_byte(sample,y)=get_byte(data,64+(floor(v+y*step)::int & 63)), 'wrong wall tap or wrap';
        END LOOP;
    END LOOP;
    SELECT array_agg(row_bytes ORDER BY y) INTO rows
    FROM (SELECT y,decode(string_agg(lpad(to_hex((13*x+7*y)&255),2,'0'),'' ORDER BY x),'hex') AS row_bytes
          FROM generate_series(0,159)x,generate_series(0,99)y GROUP BY y) r;
    cols:=doom.plane_columns(rows);
    FOR x IN 0..159 LOOP
        FOR y IN 0..99 LOOP
            ASSERT get_byte(cols[x+1],y)=get_byte(rows[y+1],x),'scanline transpose changed pixel position';
        END LOOP;
    END LOOP;
END;
$$;
