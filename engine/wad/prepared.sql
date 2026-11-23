ALTER TABLE doom.levels ADD COLUMN wad_hash bytea;
CREATE UNIQUE INDEX prepared_wad_map ON doom.levels(wad_hash,name) WHERE wad_hash IS NOT NULL;

-- Geometry, material and palette edits update the level row. Spawns are edited independently.
CREATE FUNCTION doom.forget_wad_source() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.wad_hash := NULL;
    RETURN NEW;
END;
$$;
CREATE TRIGGER forget_wad_source BEFORE UPDATE ON doom.levels
FOR EACH ROW WHEN (OLD.wad_hash IS NOT NULL) EXECUTE FUNCTION doom.forget_wad_source();

CREATE FUNCTION doom.forget_spawn_source() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_TABLE_NAME='thing_types' THEN
        PERFORM pg_advisory_xact_lock(hashtext('doom.thing_types'),0);
    END IF;
    IF TG_LEVEL='STATEMENT' THEN
        UPDATE doom.levels SET wad_hash=NULL WHERE wad_hash IS NOT NULL;
    ELSE
        UPDATE doom.levels SET wad_hash=NULL WHERE id IN (OLD.level,NEW.level) AND wad_hash IS NOT NULL;
    END IF;
    RETURN NULL;
END;
$$;
CREATE TRIGGER edited_spawns AFTER INSERT OR UPDATE OR DELETE ON doom.spawns
FOR EACH ROW EXECUTE FUNCTION doom.forget_spawn_source();
CREATE TRIGGER cleared_spawns AFTER TRUNCATE ON doom.spawns
FOR EACH STATEMENT EXECUTE FUNCTION doom.forget_spawn_source();
CREATE TRIGGER changed_sprite_map AFTER INSERT OR UPDATE OF code,sprite OR DELETE OR TRUNCATE ON doom.thing_types
FOR EACH STATEMENT EXECUTE FUNCTION doom.forget_spawn_source();

CREATE FUNCTION doom.cached_level(wad_hash bytea,map_name text) RETURNS bigint LANGUAGE sql STRICT AS $$
    -- Keep the sprite mapping stable through lookup, import and game creation.
    SELECT pg_advisory_xact_lock_shared(hashtext('doom.thing_types'),0);
    SELECT id FROM doom.levels WHERE levels.wad_hash=$1 AND name=upper($2 COLLATE "C") AND ready FOR SHARE;
$$;

CREATE FUNCTION doom.prepare_wad(wad bytea,map_name text) RETURNS bigint LANGUAGE plpgsql STRICT SET jit=off AS $$
DECLARE
    digest bytea := sha256(wad);
    map text := upper(map_name COLLATE "C");
    p bigint;
BEGIN
    p := doom.cached_level(digest,map);
    IF p IS NOT NULL THEN RETURN p; END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(encode(digest,'hex') || map,0));
    p := doom.cached_level(digest,map);
    IF p IS NULL THEN
        p := doom.load_wad(wad,map);
        UPDATE doom.levels SET wad_hash=digest WHERE id=p;
    END IF;
    RETURN p;
END;
$$;
