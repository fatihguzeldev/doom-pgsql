CREATE OR REPLACE FUNCTION doom.spawn_in_front(gid bigint,thing int) RETURNS int LANGUAGE plpgsql STRICT AS $$
DECLARE
    level_id bigint;
    body doom.actors;
    spot doom.location;
    spawned int;
BEGIN
    -- ticks and spawns take this lock before reading the player's position
    SELECT level INTO level_id FROM doom.games WHERE id=gid AND NOT finished FOR UPDATE;
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT * INTO body FROM doom.actors WHERE game=gid AND id=-1 AND health>0 FOR SHARE;
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT t.code,t.role,t.hp,t.radius,t.height,a.id
        INTO body.code,body.role,body.health,body.radius,body.height,body.art
    FROM doom.thing_types t JOIN doom.art a ON (a.level,a.kind,a.name)=(level_id,'sprite',t.sprite)
    WHERE t.code=thing AND t.role IN ('barrel','monster');
    IF NOT FOUND THEN RETURN NULL; END IF;

    spot:=doom.try_move(level_id,body,body.pos+point(64*cos(body.yaw),64*sin(body.yaw)));
    IF spot.pos IS NULL THEN RETURN NULL; END IF;
    body.pos:=spot.pos; body.sector:=spot.sector; body.z:=spot.z;
    -- movement may let an overlapping actor move away; a new actor needs a clear footprint
    IF (doom.try_move(level_id,body,body.pos)).pos IS NULL THEN RETURN NULL; END IF;

    INSERT INTO doom.actors(game,id,sector,pos,z,yaw,code,role,art,health,radius,height)
    SELECT gid,(SELECT max(id)+1 FROM doom.actors WHERE game=gid),body.sector,body.pos,body.z,
           CASE WHEN body.role='monster' THEN body.yaw+pi() ELSE 0 END,
           body.code,body.role,body.art,body.health,body.radius,body.height
    FROM doom.sectors s LEFT JOIN doom.movers m ON m.game=gid AND m.sector=s.id
    WHERE s.level=level_id AND s.id=body.sector AND body.z+body.height<=coalesce(m.ceiling_z,s.ceiling_z)
    RETURNING id INTO spawned;
    RETURN spawned;
END;
$$;

CREATE OR REPLACE FUNCTION doom.spawn_barrel(gid bigint) RETURNS int LANGUAGE sql STRICT
RETURN doom.spawn_in_front(gid,2035);

CREATE OR REPLACE FUNCTION doom.spawn_monster(gid bigint) RETURNS int LANGUAGE sql STRICT
RETURN doom.spawn_in_front(gid,3001);
