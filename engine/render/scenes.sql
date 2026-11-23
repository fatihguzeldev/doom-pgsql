CREATE FUNCTION doom.palette_revision() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.palette IS DISTINCT FROM OLD.palette OR NEW.lighting IS DISTINCT FROM OLD.lighting THEN
        NEW.revision:=OLD.revision+1;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER changed_palette BEFORE UPDATE OF palette,lighting ON doom.levels
FOR EACH ROW EXECUTE FUNCTION doom.palette_revision();

-- XOR lets an edit remove the old actor hash and add the new one in any order.
CREATE TABLE doom.actor_scenes (
    game bigint PRIMARY KEY REFERENCES doom.games ON DELETE CASCADE, signature bit(128) NOT NULL
);
CREATE FUNCTION doom.actor_mark(a doom.actors) RETURNS bit(128) LANGUAGE sql IMMUTABLE STRICT
RETURN CASE WHEN a.id<>-1 AND a.art IS NOT NULL AND a.health>0 THEN
    ('x'||md5(record_send(ROW(a.id,a.sector,a.pos,a.z,a.art))))::bit(128) ELSE 0::bit(128) END;

CREATE FUNCTION doom.actor_scene_change() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    prior bit(128);
    next_mark bit(128);
BEGIN
    IF TG_OP='INSERT' THEN
        INSERT INTO doom.actor_scenes AS scene
        SELECT a.game,bit_xor(doom.actor_mark(a::doom.actors)) FROM added a
        WHERE a.id<>-1 AND a.art IS NOT NULL AND a.health>0 GROUP BY a.game ORDER BY a.game
        ON CONFLICT(game) DO UPDATE SET signature=scene.signature#excluded.signature;
    ELSIF TG_OP='DELETE' THEN
        UPDATE doom.actor_scenes SET signature=signature#doom.actor_mark(OLD) WHERE game=OLD.game;
    ELSIF TG_OP='UPDATE' THEN
        prior:=doom.actor_mark(OLD); next_mark:=doom.actor_mark(NEW);
        IF OLD.game=NEW.game THEN
            IF prior=next_mark THEN RETURN NULL; END IF;
            next_mark:=next_mark#prior;
        ELSIF prior<>0::bit(128) THEN
            UPDATE doom.actor_scenes SET signature=signature#prior WHERE game=OLD.game;
        END IF;
        IF next_mark<>0::bit(128) THEN
            INSERT INTO doom.actor_scenes AS s VALUES(NEW.game,next_mark)
            ON CONFLICT(game) DO UPDATE SET signature=s.signature#excluded.signature;
        END IF;
    ELSE
        DELETE FROM doom.actor_scenes;
    END IF;
    RETURN NULL;
END;
$$;
CREATE TRIGGER actor_scene_added AFTER INSERT ON doom.actors REFERENCING NEW TABLE AS added
FOR EACH STATEMENT EXECUTE FUNCTION doom.actor_scene_change();
CREATE TRIGGER actor_scene_removed AFTER DELETE ON doom.actors FOR EACH ROW WHEN (OLD.id<>-1 AND OLD.art IS NOT NULL AND OLD.health>0)
EXECUTE FUNCTION doom.actor_scene_change();
CREATE TRIGGER actor_scene_updated AFTER UPDATE ON doom.actors FOR EACH ROW
WHEN ((OLD.id<>-1 OR NEW.id<>-1) AND
    (OLD.game,OLD.id,OLD.sector,OLD.pos[0],OLD.pos[1],OLD.z,OLD.art,OLD.health>0) IS DISTINCT FROM
    (NEW.game,NEW.id,NEW.sector,NEW.pos[0],NEW.pos[1],NEW.z,NEW.art,NEW.health>0))
EXECUTE FUNCTION doom.actor_scene_change();
CREATE TRIGGER actor_scene_truncated AFTER TRUNCATE ON doom.actors
FOR EACH STATEMENT EXECUTE FUNCTION doom.actor_scene_change();
