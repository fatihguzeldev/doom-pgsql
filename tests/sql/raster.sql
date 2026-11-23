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

DO $$
DECLARE
    posts doom.sprite_posts;
    idx int;
    v float8;
    step float8;
    expected int;
BEGIN
    -- All three columns have the same texels. Only columns 0 and 2 share a mask.
    ASSERT doom.wall_column_ids(decode('111211121112','hex'),decode('ffff00ffffff','hex'),3,2)=ARRAY[0,1,0];
    ASSERT doom.wall_column_ids(decode('01020304','hex'),NULL,2,2) IS NULL;
    posts:=doom.sprite_posts(decode('00000000ff00ffff0000ffff','hex'),3,4);
    ASSERT posts.offsets=ARRAY[1,1,3,4];
    ASSERT posts.runs=ARRAY[int4range(0,1),int4range(2,4),int4range(2,4)];
    FOREACH v IN ARRAY ARRAY[0,0.1,0.9999999999999999,2.5]::float8[] LOOP
        FOREACH step IN ARRAY ARRAY[0.1,0.25,1,1.3333333333333333,7]::float8[] LOOP
            FOR idx IN 0..24 LOOP
                SELECT coalesce(min(i),100) INTO expected FROM generate_series(0,99)i WHERE floor(v+i*step)>=idx;
                ASSERT doom.post_row(idx,v,step,100)=expected;
            END LOOP;
        END LOOP;
    END LOOP;
END;
$$;

DO $$
DECLARE
    tile bytea;
    depths float8[];
    first_y int;
    last_y int;
    expected bytea;
BEGIN
    SELECT decode(string_agg(lpad(to_hex((i*37+i/64)&255),2,'0'),'' ORDER BY i),'hex')
        INTO tile FROM generate_series(0,4095)i;
    SELECT array_agg(37.0::float8*80/abs(y-49.5) ORDER BY y) INTO depths FROM generate_series(0,99)y;
    FOREACH first_y IN ARRAY ARRAY[0,1,47,91,96,99] LOOP
        FOR last_y IN first_y+1..100 LOOP
            SELECT string_agg(substring(tile FROM 1+doom.flat_index(13,-9,0.8,-0.6,depths[y+1]) FOR 1),
                ''::bytea ORDER BY y) INTO expected FROM generate_series(first_y,last_y-1)y;
            ASSERT doom.plane_strip(tile,13,-9,0.8,-0.6,depths,first_y,last_y)=expected;
        END LOOP;
    END LOOP;
END;
$$;
