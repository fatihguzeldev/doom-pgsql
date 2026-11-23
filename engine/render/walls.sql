CREATE FUNCTION doom.gather8(data bytea,base int,mask int,v float8,step float8,i int)
RETURNS bytea LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
RETURN int8send(
    (get_byte(data,base+(floor(v+(i+0)*step)::int & mask))::bigint << 56)
    | (get_byte(data,base+(floor(v+(i+1)*step)::int & mask))::bigint << 48)
    | (get_byte(data,base+(floor(v+(i+2)*step)::int & mask))::bigint << 40)
    | (get_byte(data,base+(floor(v+(i+3)*step)::int & mask))::bigint << 32)
    | (get_byte(data,base+(floor(v+(i+4)*step)::int & mask))::bigint << 24)
    | (get_byte(data,base+(floor(v+(i+5)*step)::int & mask))::bigint << 16)
    | (get_byte(data,base+(floor(v+(i+6)*step)::int & mask))::bigint << 8)
    | (get_byte(data,base+(floor(v+(i+7)*step)::int & mask))::bigint << 0));

-- With an integral texture anchor, row y addresses floor(anchor+(y-49.5)*step).
-- A texel can change only at 2*k / abs(2*y-99).
CREATE TABLE doom.wall_scales (cuts float8[] NOT NULL, singleton boolean PRIMARY KEY CHECK(singleton));
INSERT INTO doom.wall_scales
SELECT array_agg(DISTINCT cut ORDER BY cut),true FROM (
    SELECT 2.0::float8*k/den AS cut FROM generate_series(1,99,2) den,
        LATERAL generate_series(0,den) k
) bounds;

-- One offset per four screen rows. The high bits select the first texel;
-- the low four bits select its substring in the compiled texture word.
ALTER TABLE doom.wall_scales ADD COLUMN quads smallint[];
WITH ranges AS (SELECT idx,(cut+lead(cut) OVER (ORDER BY idx))/2 AS step FROM doom.wall_scales,
    unnest(cuts) WITH ORDINALITY c(cut,idx)),
offsets AS (SELECT idx,y,(16*a+ (ARRAY[0,1,2,11,3,7,12,NULL::int])[1+4*(b-a)+2*(c-b)+(d-c)])::smallint AS off
    FROM ranges,generate_series(0,96,4)y,LATERAL(SELECT floor((y-49.5)*step)::int AS a,
        floor((y-48.5)*step)::int AS b,floor((y-47.5)*step)::int AS c,floor((y-46.5)*step)::int AS d) tap
    WHERE step<2.0/3)
UPDATE doom.wall_scales SET quads=(SELECT array_agg(off ORDER BY idx,y) FROM offsets);

CREATE FUNCTION doom.wall_strip(atlas bytea,col int,anchor int,mask int,offsets smallint[],i int)
RETURNS bytea LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
RETURN
    substring(atlas FROM 1+col+((anchor+offsets[i+0]) & mask) FOR 4)
    ||substring(atlas FROM 1+col+((anchor+offsets[i+1]) & mask) FOR 4)
    ||substring(atlas FROM 1+col+((anchor+offsets[i+2]) & mask) FOR 4)
    ||substring(atlas FROM 1+col+((anchor+offsets[i+3]) & mask) FOR 4)
    ||substring(atlas FROM 1+col+((anchor+offsets[i+4]) & mask) FOR 4)
    ||substring(atlas FROM 1+col+((anchor+offsets[i+5]) & mask) FOR 4)
    ||substring(atlas FROM 1+col+((anchor+offsets[i+6]) & mask) FOR 4)
    ||substring(atlas FROM 1+col+((anchor+offsets[i+7]) & mask) FOR 4)
    ||substring(atlas FROM 1+col+((anchor+offsets[i+8]) & mask) FOR 4)
    ||substring(atlas FROM 1+col+((anchor+offsets[i+9]) & mask) FOR 4)
    ||substring(atlas FROM 1+col+((anchor+offsets[i+10]) & mask) FOR 4)
    ||substring(atlas FROM 1+col+((anchor+offsets[i+11]) & mask) FOR 4)
    ||substring(atlas FROM 1+col+((anchor+offsets[i+12]) & mask) FOR 4)
    ||substring(atlas FROM 1+col+((anchor+offsets[i+13]) & mask) FOR 4)
    ||substring(atlas FROM 1+col+((anchor+offsets[i+14]) & mask) FOR 4)
    ||substring(atlas FROM 1+col+((anchor+offsets[i+15]) & mask) FOR 4)
    ||substring(atlas FROM 1+col+((anchor+offsets[i+16]) & mask) FOR 4)
    ||substring(atlas FROM 1+col+((anchor+offsets[i+17]) & mask) FOR 4)
    ||substring(atlas FROM 1+col+((anchor+offsets[i+18]) & mask) FOR 4)
    ||substring(atlas FROM 1+col+((anchor+offsets[i+19]) & mask) FOR 4)
    ||substring(atlas FROM 1+col+((anchor+offsets[i+20]) & mask) FOR 4)
    ||substring(atlas FROM 1+col+((anchor+offsets[i+21]) & mask) FOR 4)
    ||substring(atlas FROM 1+col+((anchor+offsets[i+22]) & mask) FOR 4)
    ||substring(atlas FROM 1+col+((anchor+offsets[i+23]) & mask) FOR 4)
    ||substring(atlas FROM 1+col+((anchor+offsets[i+24]) & mask) FOR 4);

-- If floor(v+i*dv) advances one row per sample, copy the column up to the next wrap.
CREATE FUNCTION doom.column_samples(colors bytea,w int,h int,u float8,v float8,dv float8,n int)
RETURNS bytea LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
    col int:=((floor(u)::int%w+w)%w)*h;
    row0 int:=floor(v)::int;
    j int:=((row0%h)+h)%h;
    phase float8:=v-row0;
    last_phase float8:=phase+(n-1)*(dv-1);
    guard float8:=1e-14*(1+abs(v)+n*abs(dv));
    result bytea;
    row_i int;
    at_i int:=0;
BEGIN
    IF n=1 THEN RETURN substring(colors FROM col+j+1 FOR 1); END IF;
    IF n<=h AND ((dv=1 AND phase=0) OR (least(phase,last_phase)>guard AND greatest(phase,last_phase)<1-guard)) THEN
        IF j+n<=h THEN RETURN substring(colors FROM col+j+1 FOR n); END IF;
        RETURN substring(colors FROM col+j+1 FOR h-j)||substring(colors FROM col+1 FOR n-(h-j));
    END IF;
    IF floor(v+(n-1)*dv)=row0 THEN RETURN decode(repeat(encode(substring(colors FROM col+j+1 FOR 1),'hex'),n),'hex'); END IF;
    result:=''::bytea;
    IF (h&(h-1))=0 THEN
        WHILE at_i+8<=n LOOP
            result:=result||doom.gather8(colors,col,h-1,v,dv,at_i);
            at_i:=at_i+8;
        END LOOP;
        IF at_i<n AND n>=8 THEN
            result:=result||substring(doom.gather8(colors,col,h-1,v,dv,n-8) FROM 9-(n-at_i));
        ELSE
            FOR i IN at_i..n-1 LOOP
                result:=result||substring(colors FROM 1+col+(floor(v+i*dv)::int & (h-1)) FOR 1);
            END LOOP;
        END IF;
    ELSE
        result:=decode(repeat('00',n),'hex');
        FOR i IN 0..n-1 LOOP
            row_i:=floor(v+i*dv)::int;
            result:=set_byte(result,i,get_byte(colors,col+(row_i%h+h)%h));
        END LOOP;
    END IF;
    RETURN result;
END;
$$;

-- First sampled row at or beyond a post boundary. Check the forward expression
-- at the estimate so division cannot move an exact texel boundary by one pixel.
CREATE FUNCTION doom.post_row(edge int,v float8,dv float8,n int) RETURNS int
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
    SELECT CASE WHEN i>0 AND v+(i-1)*dv>=edge THEN i-1
                WHEN i<n AND v+i*dv<edge THEN i+1 ELSE i END
    FROM (SELECT greatest(0,least(n,ceil((edge-v)/dv)))::int AS i) q;
$$;
