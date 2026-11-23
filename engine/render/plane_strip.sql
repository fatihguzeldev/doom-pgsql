CREATE OR REPLACE FUNCTION doom.plane_strip(data bytea,px float8,py float8,dx float8,dy float8,depths float8[],y0 int,y1 int)
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
        tail:=least(y,cardinality(depths)-8);
        strip:=strip||substring(doom.plane_eight(data,px,py,dx,dy,depths,tail+1) FROM 1+y-tail FOR y1-y);
    END IF;
    RETURN strip;
END;
$$;
