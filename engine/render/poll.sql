CREATE OR REPLACE FUNCTION doom.poll_frame(gid bigint,generation bigint,slot bigint,previous text,frame_width int,frame_height int)
RETURNS TABLE(epoch bigint,tic bigint,frame_slot bigint,width int,height int,pixels bytea,shades bytea,
    token text,palette_revision bigint,camera_x float8,camera_y float8,camera_z float8,yaw float8,finished boolean)
LANGUAGE plpgsql STABLE SET jit=off AS $$
DECLARE
    lvl bigint;
    people text;
    cam doom.viewports;
BEGIN
    IF frame_width IS NULL OR frame_height IS NULL OR frame_width NOT BETWEEN 1 AND 4096
        OR frame_height NOT BETWEEN 8 AND 4096 THEN
        RAISE EXCEPTION 'expected a width of 1..4096 and a height of 8..4096' USING ERRCODE='22023';
    END IF;
    SELECT g.epoch,g.tic,g.level,l.revision,a.pos[0],a.pos[1],a.z,a.yaw,g.finished,
        md5(record_send(ROW(a.sector,a.pos,a.z,a.yaw,a.art,coalesce(scene.signature,0::bit(128)))))
    INTO STRICT epoch,tic,lvl,palette_revision,camera_x,camera_y,camera_z,yaw,finished,people
    FROM doom.games g JOIN doom.levels l ON l.id=g.level JOIN doom.actors a ON a.game=g.id AND a.id=-1
    LEFT JOIN doom.actor_scenes scene ON scene.game=g.id WHERE g.id=gid;
    IF generation IS DISTINCT FROM epoch OR slot IS NULL OR slot<0 THEN RAISE EXCEPTION 'invalid polling cursor' USING ERRCODE='22023'; END IF;
    token:=md5(concat_ws('/',gid,generation,lvl,palette_revision,people,doom.opening_key(gid)));
    width:=frame_width; height:=frame_height; frame_slot:=slot;
    IF (width,height)<>(160,100) THEN token:=width || 'x' || height || '/' || token; END IF;
    IF token IS DISTINCT FROM previous THEN
        SELECT v.* INTO cam FROM doom.viewports v WHERE v.w=frame_width AND v.h=frame_height;
        IF NOT FOUND THEN cam:=doom.make_viewport(width,height); END IF;
        SELECT f.pixels,f.shades INTO pixels,shades FROM doom.raster(gid,generation,slot,false,cam) f;
    END IF;
    RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION doom.poll_frame(gid bigint,generation bigint,slot bigint,previous text,frame_width int)
RETURNS TABLE(epoch bigint,tic bigint,frame_slot bigint,width int,height int,pixels bytea,shades bytea,
    token text,palette_revision bigint,camera_x float8,camera_y float8,camera_z float8,yaw float8,finished boolean)
LANGUAGE sql STABLE AS $$
    SELECT * FROM doom.poll_frame(gid,generation,slot,previous,frame_width,(frame_width::bigint*5/8)::int);
$$;

CREATE OR REPLACE FUNCTION doom.poll_frame(gid bigint,generation bigint,slot bigint,previous text DEFAULT NULL)
RETURNS TABLE(epoch bigint,tic bigint,frame_slot bigint,width int,height int,pixels bytea,shades bytea,
    token text,palette_revision bigint,camera_x float8,camera_y float8,camera_z float8,yaw float8,finished boolean)
LANGUAGE sql STABLE AS $$
    SELECT * FROM doom.poll_frame(gid,generation,slot,previous,160);
$$;

CREATE OR REPLACE FUNCTION doom.poll_frame_low(gid bigint,generation bigint,slot bigint,previous text DEFAULT NULL)
RETURNS TABLE(epoch bigint,tic bigint,frame_slot bigint,width int,height int,pixels bytea,shades bytea,
    token text,palette_revision bigint,camera_x float8,camera_y float8,camera_z float8,yaw float8,finished boolean)
LANGUAGE sql STABLE AS $$
    SELECT * FROM doom.poll_frame(gid,generation,slot,previous,64);
$$;

-- each hash covers up to eight columns. pass null for known to request all strips.
CREATE OR REPLACE FUNCTION doom.poll_tiles(gid bigint,generation bigint,slot bigint,previous text,known text[],frame_width int,frame_height int)
RETURNS TABLE(epoch bigint,tic bigint,frame_slot bigint,width int,height int,pixels bytea,shades bytea,
    token text,palette_revision bigint,camera_x float8,camera_y float8,camera_z float8,yaw float8,finished boolean,
    tiles int[],hashes text[])
LANGUAGE plpgsql STABLE AS $$
DECLARE
    f record;
BEGIN
    IF cardinality(known) IS DISTINCT FROM ((frame_width::bigint+7)/8) OR array_lower(known,1)<>1 THEN known:=NULL; END IF;
    SELECT * INTO STRICT f FROM doom.poll_frame(gid,generation,slot,CASE WHEN known IS NOT NULL
        AND array_position(known,NULL) IS NULL THEN previous END,frame_width,frame_height);
    epoch:=f.epoch; tic:=f.tic; frame_slot:=f.frame_slot; width:=f.width; height:=f.height;
    token:=f.token; palette_revision:=f.palette_revision; camera_x:=f.camera_x; camera_y:=f.camera_y;
    camera_z:=f.camera_z; yaw:=f.yaw; finished:=f.finished;
    IF f.pixels IS NULL THEN hashes:=known; tiles:='{}';
    ELSE
        WITH chunks AS MATERIALIZED (
            SELECT i,substring(f.pixels FROM 1+8*height*i FOR 8*height) AS color,
                substring(f.shades FROM 1+8*height*i FOR 8*height) AS light FROM generate_series(0,(width-1)/8)i
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

CREATE OR REPLACE FUNCTION doom.poll_tiles(gid bigint,generation bigint,slot bigint,previous text,known text[])
RETURNS TABLE(epoch bigint,tic bigint,frame_slot bigint,width int,height int,pixels bytea,shades bytea,
    token text,palette_revision bigint,camera_x float8,camera_y float8,camera_z float8,yaw float8,finished boolean,
    tiles int[],hashes text[])
LANGUAGE sql STABLE AS $$
    SELECT * FROM doom.poll_tiles(gid,generation,slot,previous,known,160,100);
$$;

-- poll again if a palette edit invalidates this revision.
CREATE OR REPLACE FUNCTION doom.frame_palette(gid bigint,wanted_revision bigint) RETURNS bytea
LANGUAGE sql STABLE STRICT AS $$
    SELECT doom.frame_palette(gid) FROM doom.games g JOIN doom.levels l ON l.id=g.level
    WHERE g.id=gid AND l.revision=wanted_revision;
$$;
