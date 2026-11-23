CREATE FUNCTION doom.load_wad(wad bytea, map_name text) RETURNS bigint
LANGUAGE plpgsql STRICT AS $$
DECLARE
    directory doom.lump[];
    catalog jsonb;
    p bigint;
BEGIN
    SELECT array_agg(d ORDER BY ordinal),jsonb_object_agg(name,jsonb_build_array(pos,size) ORDER BY ordinal)
    INTO directory,catalog FROM doom.directory(wad) d;
    p := doom.read_map(wad,upper(map_name COLLATE "C"),catalog,directory);
    PERFORM doom.read_art(p,wad,catalog);
    UPDATE doom.levels SET ready=true WHERE id=p;
    RETURN p;
END;
$$;
