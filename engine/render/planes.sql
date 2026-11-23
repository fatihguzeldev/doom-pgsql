CREATE FUNCTION doom.flat_index(px float8,py float8,dx float8,dy float8,z float8)
RETURNS int LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
RETURN ((floor(px+dx*z)::bigint & 63) | ((floor(py+dy*z)::bigint & 63)<<6))::int;

CREATE FUNCTION doom.plane_eight(data bytea,px float8,py float8,dx float8,dy float8,depths float8[],i int)
RETURNS bytea LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
RETURN int8send(
    (get_byte(data,doom.flat_index(px,py,dx,dy,depths[i+0]))::bigint << 56)
    | (get_byte(data,doom.flat_index(px,py,dx,dy,depths[i+1]))::bigint << 48)
    | (get_byte(data,doom.flat_index(px,py,dx,dy,depths[i+2]))::bigint << 40)
    | (get_byte(data,doom.flat_index(px,py,dx,dy,depths[i+3]))::bigint << 32)
    | (get_byte(data,doom.flat_index(px,py,dx,dy,depths[i+4]))::bigint << 24)
    | (get_byte(data,doom.flat_index(px,py,dx,dy,depths[i+5]))::bigint << 16)
    | (get_byte(data,doom.flat_index(px,py,dx,dy,depths[i+6]))::bigint << 8)
    | (get_byte(data,doom.flat_index(px,py,dx,dy,depths[i+7]))::bigint << 0));

CREATE FUNCTION doom.plane_strip(data bytea,px float8,py float8,dx float8,dy float8,depths float8[],y0 int,y1 int)
RETURNS bytea LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
    y int:=y0;
    tail int;
    strip bytea:=''::bytea;
BEGIN
    WHILE y+8<=y1 LOOP
        strip:=strip||doom.plane_eight(data,px,py,dx,dy,depths,y+1);
        y:=y+8;
    END LOOP;
    IF y<y1 THEN
        tail:=least(y,92);
        strip:=strip||substring(doom.plane_eight(data,px,py,dx,dy,depths,tail+1) FROM 1+y-tail FOR y1-y);
    END IF;
    RETURN strip;
END;
$$;

-- Match the column renderer's rounding at texel boundaries.
CREATE FUNCTION doom.flat_eight(data bytea,px float8,py float8,rx float8[],ry float8[],z float8,i int)
RETURNS bytea LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
RETURN int8send(
    (get_byte(data,doom.flat_index(px,py,rx[i+0],ry[i+0],z))::bigint << 56)
    | (get_byte(data,doom.flat_index(px,py,rx[i+1],ry[i+1],z))::bigint << 48)
    | (get_byte(data,doom.flat_index(px,py,rx[i+2],ry[i+2],z))::bigint << 40)
    | (get_byte(data,doom.flat_index(px,py,rx[i+3],ry[i+3],z))::bigint << 32)
    | (get_byte(data,doom.flat_index(px,py,rx[i+4],ry[i+4],z))::bigint << 24)
    | (get_byte(data,doom.flat_index(px,py,rx[i+5],ry[i+5],z))::bigint << 16)
    | (get_byte(data,doom.flat_index(px,py,rx[i+6],ry[i+6],z))::bigint << 8)
    | (get_byte(data,doom.flat_index(px,py,rx[i+7],ry[i+7],z))::bigint << 0));

CREATE TYPE doom.plane_lut AS (depths float8[],bands bytea);
CREATE TABLE doom.plane_tables (
    level bigint REFERENCES doom.levels ON DELETE CASCADE, distance int, light int, lut doom.plane_lut NOT NULL,
    PRIMARY KEY(level,distance,light)
);
CREATE FUNCTION doom.make_plane_lut(delta float8,light int,bands int,rays float8[])
RETURNS doom.plane_lut LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT ROW(array_agg(z ORDER BY y),decode(string_agg(lpad(to_hex(least(bands,(255-light)/8+floor(z/96)::int)),
        2,'0'),'' ORDER BY y),'hex'))::doom.plane_lut
    FROM unnest(rays) WITH ORDINALITY r(scale,y), LATERAL(SELECT delta*scale AS z) d;
$$;
CREATE FUNCTION doom.compile_plane_tables() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    DELETE FROM doom.plane_tables WHERE level=NEW.id;
    INSERT INTO doom.plane_tables
    SELECT NEW.id,delta,light,doom.make_plane_lut(delta,light,least(32,length(NEW.lighting)/256)-1,s.row_scale)
    FROM (
        SELECT DISTINCT abs(altitude-target) AS delta,room.light
        FROM doom.sectors room JOIN doom.mesh m ON m.level=room.level AND m.sector=room.id,
        LATERAL (SELECT room.floor_z+41 AS altitude UNION
            SELECT near.floor_z+41 FROM unnest(m.edges)e JOIN doom.sectors near ON near.level=NEW.id AND near.id=e.dest) camera,
        LATERAL (VALUES(room.floor_z),(room.ceiling_z)) surface(target)
        WHERE room.level=NEW.id
    ) planes CROSS JOIN doom.screen s;
    RETURN NULL;
END;
$$;
CREATE TRIGGER compile_plane_tables AFTER UPDATE OF revision,lighting ON doom.levels
FOR EACH ROW EXECUTE FUNCTION doom.compile_plane_tables();

-- Pack twenty 32x32 tiles, transpose their bytes together with five bit
-- permutations, then join the four vertical pieces of each screen column.
CREATE TABLE doom.transpose_masks (masks varbit[] NOT NULL, singleton boolean PRIMARY KEY CHECK(singleton));
INSERT INTO doom.transpose_masks
SELECT array_agg(('x'||repeat(tile,20))::varbit ORDER BY b),true
FROM (SELECT b,string_agg(CASE WHEN ((i/32)&(1<<b))<>0 AND (i&(1<<b))=0 THEN 'ff' ELSE '00' END,'' ORDER BY i) AS tile
      FROM generate_series(0,4)b CROSS JOIN generate_series(0,1023)i GROUP BY b)m;

CREATE FUNCTION doom.plane_columns(rows bytea[]) RETURNS bytea[] LANGUAGE plpgsql STABLE STRICT AS $$
DECLARE
    bits varbit;
    swap varbit;
    masks varbit[];
    packed bytea;
    zeros bytea:=decode(repeat('00',32),'hex');
    shift_bits int;
    cols bytea[];
BEGIN
    SELECT ('x'||encode(string_agg(coalesce(substring(rows[1+ty*32+y] FROM 1+tx*32 FOR 32),zeros),
        ''::bytea ORDER BY tx,ty,y),'hex'))::varbit INTO bits
    FROM generate_series(0,4)tx,generate_series(0,3)ty,generate_series(0,31)y;
    SELECT m.masks INTO masks FROM doom.transpose_masks m;
    FOR b IN 0..4 LOOP
        shift_bits:=248*(1<<b);
        swap:=((bits>>shift_bits)#bits)&masks[b+1];
        bits:=bits#swap#(swap<<shift_bits);
    END LOOP;
    packed:=substring(varbit_send(bits) FROM 5);
    SELECT array_agg(substring(packed FROM off FOR 32)||substring(packed FROM off+1024 FOR 32)||
        substring(packed FROM off+2048 FOR 32)||substring(packed FROM off+3072 FOR 4) ORDER BY x) INTO cols
    FROM generate_series(0,159)x,LATERAL (SELECT 1+4096*(x/32)+32*(x%32) AS off)s;
    RETURN cols;
END;
$$;

CREATE FUNCTION doom.flat_background(world doom.stroke[],px float8,py float8,fx float8,fy float8,eye float8,scales float8[])
RETURNS bytea[] LANGUAGE plpgsql STABLE STRICT AS $$
DECLARE
    rows bytea[]:=array_fill(decode(repeat('00',160),'hex'),ARRAY[100]);
    rx float8[]; ry float8[];
    plane record;
    prev bit(100);
    mask bit(100);
    changes bit(100);
    empty_mask bit(100):=0::bit(100);
    full_mask bit(100):=~empty_mask;
    cover bit(100)[];
    starts int[]:=array_fill(0,ARRAY[100],ARRAY[0]);
    span doom.stroke;
    x int; y int; i int; start_x int;
    depth float8;
    strip bytea;
    tile bytea;
BEGIN
    SELECT array_agg(fx+fy*(col-79.5)/80 ORDER BY col),array_agg(-(fy-fx*(col-79.5)/80) ORDER BY col)
    INTO rx,ry FROM generate_series(0,159)col;
    FOR plane IN SELECT w.art,w.v,array_agg(w) AS strokes FROM unnest(world)w
        WHERE w.kind=0 AND w.art IS NOT NULL GROUP BY w.art,w.v LOOP
        SELECT substring(a.pixels FROM 1) INTO STRICT tile FROM doom.art a WHERE a.id=plane.art;
        cover:=array_fill(empty_mask,ARRAY[161],ARRAY[0]);
        FOREACH span IN ARRAY plane.strokes LOOP
            cover[span.x]:=overlay(cover[span.x] PLACING substring(full_mask FROM 1 FOR span.y1-span.y0) FROM span.y0+1);
        END LOOP;
        prev:=empty_mask;
        FOR x IN 0..160 LOOP
            mask:=cover[x];
            CONTINUE WHEN prev=mask;
            changes:=mask#prev; prev:=mask;
            WHILE changes<>empty_mask LOOP
                y:=position(B'1' IN changes)-1;
                changes:=set_bit(changes,y,0);
                IF get_bit(mask,y)=1 THEN starts[y]:=x; CONTINUE; END IF;
                depth:=abs(eye-plane.v)*scales[1+y]; start_x:=starts[y]; i:=start_x;
                strip:=''::bytea;
                WHILE i+8<=x LOOP
                    strip:=strip||doom.flat_eight(tile,px,py,rx,ry,depth,i+1); i:=i+8;
                END LOOP;
                WHILE i<x LOOP
                    strip:=strip||substring(tile FROM 1+doom.flat_index(px,py,rx[i+1],ry[i+1],depth) FOR 1); i:=i+1;
                END LOOP;
                rows[y+1]:=overlay(rows[y+1] PLACING strip FROM start_x+1);
            END LOOP;
        END LOOP;
    END LOOP;
    RETURN doom.plane_columns(rows);
END;
$$;
