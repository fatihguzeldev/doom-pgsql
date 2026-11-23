-- wad offsets start at zero.
CREATE FUNCTION doom.u16(b bytea, i int) RETURNS int
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
RETURN get_byte(b,i) + 256 * get_byte(b,i+1);

CREATE FUNCTION doom.s16(b bytea, i int) RETURNS int
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
RETURN (doom.u16(b,i) # 32768) - 32768;

CREATE FUNCTION doom.u32(b bytea, i int) RETURNS bigint
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
RETURN doom.u16(b,i) + 65536::bigint * doom.u16(b,i+2);

CREATE FUNCTION doom.label(b bytea, i int) RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
RETURN upper(convert_from(substring(b FROM i+1 FOR
    coalesce(nullif(position(decode('00','hex') IN substring(b FROM i+1 FOR 8)),0)-1,8)), 'LATIN1') COLLATE "C");

CREATE TYPE doom.lump AS (ordinal int, name text, pos int, size int);

CREATE FUNCTION doom.directory(wad bytea) RETURNS SETOF doom.lump
LANGUAGE plpgsql IMMUTABLE STRICT AS $$
DECLARE
    n bigint;
    directory_at bigint;
    at_byte int;
    pos bigint;
    size bigint;
BEGIN
    IF length(wad) < 12 OR substring(wad FOR 4) NOT IN ('IWAD'::bytea,'PWAD'::bytea) THEN
        RAISE EXCEPTION 'expected a classic IWAD or PWAD' USING ERRCODE='22023';
    END IF;
    n := doom.u32(wad,4);
    directory_at := doom.u32(wad,8);
    IF directory_at + 16*n > length(wad) THEN
        RAISE EXCEPTION 'lump directory exceeds archive' USING ERRCODE='22023';
    END IF;
    FOR i IN 0..n::int-1 LOOP
        at_byte := directory_at + 16*i;
        pos := doom.u32(wad,at_byte);
        size := doom.u32(wad,at_byte+4);
        IF size > 0 AND pos+size > length(wad) THEN
            RAISE EXCEPTION 'lump % exceeds archive',i USING ERRCODE='22023';
        END IF;
        RETURN NEXT (i,doom.label(wad,at_byte+8),CASE WHEN size=0 THEN 0 ELSE pos::int END,size::int)::doom.lump;
    END LOOP;
END;
$$;

CREATE FUNCTION doom.lump_data(wad bytea, catalog jsonb, name text) RETURNS bytea
LANGUAGE sql IMMUTABLE STRICT
RETURN substring(wad FROM (catalog->name->>0)::int+1 FOR (catalog->name->>1)::int);

CREATE FUNCTION doom.record_count(data bytea, stride int) RETURNS int
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF data IS NULL OR length(data)%stride<>0 THEN
        RAISE EXCEPTION 'missing or incomplete %-byte WAD record',stride USING ERRCODE='22023';
    END IF;
    RETURN length(data)/stride;
END;
$$;
