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

CREATE FUNCTION doom.poll_frame(gid bigint,generation bigint,slot bigint,previous text DEFAULT NULL)
RETURNS TABLE(epoch bigint,tic bigint,frame_slot bigint,width int,height int,pixels bytea,shades bytea,
    token text,palette_revision bigint,camera_x float8,camera_y float8,camera_z float8,yaw float8,finished boolean)
LANGUAGE plpgsql STABLE SET jit=off AS $$
DECLARE
    lvl bigint;
    people text;

BEGIN
    SELECT g.epoch,g.tic,g.level,l.revision,a.pos[0],a.pos[1],a.z,a.yaw,g.finished,
        md5(record_send(ROW(a.sector,a.pos,a.z,a.yaw,a.art,coalesce(scene.signature,0::bit(128)))))
    INTO STRICT epoch,tic,lvl,palette_revision,camera_x,camera_y,camera_z,yaw,finished,people
    FROM doom.games g JOIN doom.levels l ON l.id=g.level JOIN doom.actors a ON a.game=g.id AND a.id=-1
    LEFT JOIN doom.actor_scenes scene ON scene.game=g.id WHERE g.id=gid;
    IF generation IS DISTINCT FROM epoch OR slot IS NULL OR slot<0 THEN RAISE EXCEPTION 'invalid polling cursor' USING ERRCODE='22023'; END IF;
    token:=md5(concat_ws('/',gid,generation,lvl,palette_revision,people,doom.opening_key(gid)));
    width:=160; height:=100; frame_slot:=slot;
    IF token IS DISTINCT FROM previous THEN
        SELECT f.pixels,f.shades INTO pixels,shades FROM doom.frame(gid,generation,slot) f;
    END IF;
    RETURN NEXT;
END;
$$;

-- Each hash covers eight columns. Pass NULL for known to request all 20 strips.
CREATE FUNCTION doom.poll_tiles(gid bigint,generation bigint,slot bigint,previous text,known text[])
RETURNS TABLE(epoch bigint,tic bigint,frame_slot bigint,width int,height int,pixels bytea,shades bytea,
    token text,palette_revision bigint,camera_x float8,camera_y float8,camera_z float8,yaw float8,finished boolean,
    tiles int[],hashes text[])
LANGUAGE plpgsql STABLE AS $$
DECLARE
    f record;
BEGIN
    IF cardinality(known) IS DISTINCT FROM 20 OR array_lower(known,1)<>1 THEN known:=NULL; END IF;
    SELECT * INTO STRICT f FROM doom.poll_frame(gid,generation,slot,CASE WHEN known IS NOT NULL
        AND array_position(known,NULL) IS NULL THEN previous END);
    epoch:=f.epoch; tic:=f.tic; frame_slot:=f.frame_slot; width:=f.width; height:=f.height;
    token:=f.token; palette_revision:=f.palette_revision; camera_x:=f.camera_x; camera_y:=f.camera_y;
    camera_z:=f.camera_z; yaw:=f.yaw; finished:=f.finished;
    IF f.pixels IS NULL THEN hashes:=known; tiles:='{}';
    ELSE
        WITH chunks AS MATERIALIZED (
            SELECT i,substring(f.pixels FROM 1+800*i FOR 800) AS color,
                substring(f.shades FROM 1+800*i FOR 800) AS light FROM generate_series(0,19)i
        ), compared AS MATERIALIZED (
            SELECT *,md5(color||light) AS hash FROM chunks
        )
        SELECT array_agg(hash ORDER BY i),coalesce(array_agg(i ORDER BY i) FILTER(WHERE dirty),'{}'),
            string_agg(color,''::bytea ORDER BY i) FILTER(WHERE dirty),string_agg(light,''::bytea ORDER BY i) FILTER(WHERE dirty)
        INTO hashes,tiles,pixels,shades FROM compared,LATERAL(SELECT hash IS DISTINCT FROM known[i+1] AS dirty) change;
    END IF;
    RETURN NEXT;
END;
$$;

-- If the frame revision is stale, the palette lookup returns NULL. Poll again.
CREATE FUNCTION doom.frame_palette(gid bigint,wanted_revision bigint) RETURNS bytea
LANGUAGE sql STABLE STRICT AS $$
    SELECT doom.frame_palette(gid) FROM doom.games g JOIN doom.levels l ON l.id=g.level
    WHERE g.id=gid AND l.revision=wanted_revision;
$$;
