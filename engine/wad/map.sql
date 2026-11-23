CREATE FUNCTION doom.read_map(wad bytea, map_name text, catalog jsonb, directory doom.lump[]) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    marker int;
    parts bytea[];
    names text[];
    vertices point[];
    p bigint;
    n int;
BEGIN
    SELECT max(d.ordinal) INTO marker FROM unnest(directory) d WHERE d.name=map_name;
    SELECT array_agg(d.name ORDER BY d.ordinal),
           array_agg(substring(wad FROM d.pos+1 FOR d.size) ORDER BY d.ordinal)
      INTO names,parts FROM unnest(directory) d WHERE d.ordinal BETWEEN marker+1 AND marker+11;
    IF names[1:8] IS DISTINCT FROM ARRAY['THINGS','LINEDEFS','SIDEDEFS','VERTEXES','SEGS','SSECTORS','NODES','SECTORS']
       OR NOT (names[9]='BLOCKMAP' OR (names[9]='REJECT' AND names[10]='BLOCKMAP'))
       OR 'BEHAVIOR'=ANY(names) THEN
        RAISE EXCEPTION 'missing or unsupported classic map %',map_name USING ERRCODE='22023';
    END IF;
    n := doom.record_count(parts[8],26);
    INSERT INTO doom.levels(name,palette,lighting,sector_count,reject)
    VALUES (map_name,substring(doom.lump_data(wad,catalog,'PLAYPAL') FOR 768),
        doom.lump_data(wad,catalog,'COLORMAP'),n,CASE WHEN names[9]='REJECT'
        AND length(parts[9]) >= (n::bigint*n+7)/8 THEN parts[9] END)
    RETURNING id INTO p;
    INSERT INTO doom.sectors
    SELECT p,i,doom.s16(raw,i*26),doom.s16(raw,i*26+2),doom.label(raw,i*26+4),doom.label(raw,i*26+12),
        doom.u16(raw,i*26+20),doom.u16(raw,i*26+22),doom.u16(raw,i*26+24)
    FROM (VALUES(parts[8])) data(raw), generate_series(0,n-1) i;

    SELECT array_agg(point(doom.s16(raw,i*4),doom.s16(raw,i*4+2)) ORDER BY i) INTO vertices
    FROM (VALUES(parts[4])) data(raw),generate_series(0,doom.record_count(raw,4)-1) i;
    INSERT INTO doom.sides
    SELECT p,i,doom.u16(raw,i*30+28),doom.s16(raw,i*30),doom.s16(raw,i*30+2),
        nullif(doom.label(raw,i*30+4),'-'),nullif(doom.label(raw,i*30+12),'-'),nullif(doom.label(raw,i*30+20),'-')
    FROM (VALUES(parts[3])) data(raw),generate_series(0,doom.record_count(raw,30)-1) i;

    INSERT INTO doom.lines
    SELECT p,i,vertices[1+doom.u16(raw,i*14)],vertices[1+doom.u16(raw,i*14+2)],
        doom.u16(raw,i*14+10),nullif(doom.u16(raw,i*14+12),65535),doom.u16(raw,i*14+4),
        doom.u16(raw,i*14+6),doom.u16(raw,i*14+8)
    FROM (VALUES(parts[2])) data(raw),generate_series(0,doom.record_count(raw,14)-1) i;

    INSERT INTO doom.spawns
    SELECT p,i,point(doom.s16(raw,i*10),doom.s16(raw,i*10+2)),doom.u16(raw,i*10+4),
        doom.u16(raw,i*10+6),doom.u16(raw,i*10+8)
    FROM (VALUES(parts[1])) data(raw),generate_series(0,doom.record_count(raw,10)-1) i;
    RETURN p;
END;
$$;
