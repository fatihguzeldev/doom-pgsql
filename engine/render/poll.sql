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

CREATE FUNCTION doom.poll_frame(gid bigint,generation bigint,slot bigint,previous text DEFAULT NULL)
RETURNS TABLE(epoch bigint,tic bigint,frame_slot bigint,width int,height int,pixels bytea,shades bytea,
    token text,palette_revision bigint,camera_x float8,camera_y float8,camera_z float8,yaw float8,finished boolean)
LANGUAGE plpgsql STABLE SET jit=off AS $$
DECLARE
    lvl bigint;
    people text;
    doors text;
BEGIN
    SELECT g.epoch,g.tic,g.level,l.revision,a.pos[0],a.pos[1],a.z,a.yaw,g.finished
    INTO STRICT epoch,tic,lvl,palette_revision,camera_x,camera_y,camera_z,yaw,finished
    FROM doom.games g JOIN doom.levels l ON l.id=g.level JOIN doom.actors a ON a.game=g.id AND a.id=-1 WHERE g.id=gid;
    IF generation IS DISTINCT FROM epoch OR slot IS NULL OR slot<0 THEN RAISE EXCEPTION 'invalid polling cursor' USING ERRCODE='22023'; END IF;
    -- The digest includes external SQL edits even when game.tic did not advance.
    SELECT string_agg(ROW(a.id,a.sector,a.pos,a.z,a.art,CASE WHEN a.id=-1 THEN a.yaw END)::text,'|' ORDER BY a.id)
    INTO people FROM doom.actors a WHERE a.game=gid AND (a.id=-1 OR a.art IS NOT NULL AND a.health>0);
    SELECT string_agg(ROW(m.sector,m.floor_z,m.ceiling_z)::text,'|' ORDER BY m.sector) INTO doors
    FROM doom.movers m WHERE m.game=gid;
    token:=md5(concat_ws('/',gid,generation,lvl,palette_revision,people,doors));
    width:=160; height:=100; frame_slot:=slot;
    IF token IS DISTINCT FROM previous THEN
        SELECT f.pixels,f.shades INTO pixels,shades FROM doom.frame(gid,generation,slot) f;
    END IF;
    RETURN NEXT;
END;
$$;

-- Twenty independently replaceable strips, each containing eight full columns.
-- A missing hash vector requests a keyframe. The SQL frame layout stays unchanged.
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
