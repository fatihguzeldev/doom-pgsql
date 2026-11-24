CREATE OR REPLACE FUNCTION doom.tick(gid bigint,generation bigint,n bigint,forward float8,strafe float8,turn float8,
    use_line boolean,fire boolean) RETURNS bigint LANGUAGE plpgsql SET jit=off SET plan_cache_mode=force_generic_plan AS $$
DECLARE
    cmd doom.command := (forward,strafe,turn,use_line,fire);
    g doom.games;
    player doom.actors;
    foe doom.actors;
    loc doom.location;
    delta point;
    facing point;
    before_pos point;
    dist float8;
    contact record;
    target_id int;
    damage int := 0;
    matrix bytea;
    bit_index bigint;
    sectors int;
    write_turn boolean;
BEGIN
    IF NOT (cmd IS NOT NULL) OR gid IS NULL OR generation IS NULL OR n IS NULL OR n<1
        OR abs(forward)>1 OR abs(strafe)>1 OR abs(turn)>pi() THEN RAISE EXCEPTION 'invalid input' USING ERRCODE='22023'; END IF;
    UPDATE doom.games SET tic=n,last_command=cmd,
        still_tics=CASE WHEN forward=0 AND strafe=0 AND turn=0 THEN least(4,still_tics+1) ELSE 0 END
    WHERE id=gid AND epoch=generation AND tic=n-1 AND NOT finished RETURNING * INTO g;
    IF NOT FOUND THEN
        SELECT * INTO STRICT g FROM doom.games WHERE id=gid;
        IF g.epoch<>generation OR (g.tic=n AND cmd IS DISTINCT FROM g.last_command) THEN
            RAISE EXCEPTION 'conflicting game generation or input' USING ERRCODE='22023';
        END IF;
        IF n<=g.tic OR g.finished THEN RETURN g.tic; END IF;
        RAISE EXCEPTION 'expected tic %, got %',g.tic+1,n USING ERRCODE='22023';
    END IF;
    PERFORM 1 FROM doom.levels WHERE id=g.level FOR SHARE;
    PERFORM doom.advance(gid,n);
    SELECT * INTO STRICT player FROM doom.actors WHERE game=gid AND id=-1 FOR UPDATE;
    IF player.health<=0 THEN RETURN n; END IF;
    player.yaw := player.yaw+turn;
    player.yaw := player.yaw-floor(player.yaw/(2*pi()))*(2*pi());
    -- an exit switch can end the tic before movement saves the new yaw.
    write_turn:=turn<>0 AND (forward<>0 OR strafe<>0) AND NOT use_line AND NOT fire;
    IF turn<>0 AND NOT write_turn THEN UPDATE doom.actors SET yaw=player.yaw WHERE game=gid AND id=-1; END IF;
    facing := point(cos(player.yaw),sin(player.yaw));
    IF use_line OR (fire AND g.ammo>0 AND g.next_shot<=n) THEN
        FOR contact IN SELECT t.*,l.special FROM doom.trace(g.level,gid,player.pos,
            point(facing[0]*CASE WHEN fire THEN 1024 ELSE 64 END,facing[1]*CASE WHEN fire THEN 1024 ELSE 64 END),
            player.sector,player.z+41)t JOIN doom.lines l ON l.level=g.level AND l.id=t.line
            ORDER BY t.t,t.line
        LOOP
            IF contact.special<>0 AND use_line AND contact.t*(CASE WHEN fire THEN 1024 ELSE 64 END)<=64 THEN
                PERFORM doom.activate(g,contact.line,'use'); use_line:=false;
                IF EXISTS(SELECT FROM doom.games WHERE id=gid AND finished) THEN RETURN n; END IF;
            END IF;
            IF contact.blocked THEN
                dist:=contact.t*CASE WHEN fire THEN 1024 ELSE 64 END;
                IF fire AND g.ammo>0 AND g.next_shot<=n THEN PERFORM doom.activate(g,contact.line,'shoot'); END IF;
                EXIT;
            END IF;
        END LOOP;
        IF fire AND g.ammo>0 AND g.next_shot<=n THEN
            SELECT a.id INTO target_id FROM doom.actors a, LATERAL (SELECT a.pos-player.pos AS d) off,
                LATERAL (SELECT d[0]*facing[0]+d[1]*facing[1] AS along,abs(d[0]*facing[1]-d[1]*facing[0]) AS side) ray
            WHERE a.game=gid AND a.role IN ('monster','barrel') AND a.health>0 AND ray.side<=a.radius
                AND ray.along BETWEEN 0 AND coalesce(dist,1024)+a.radius AND player.z+41 BETWEEN a.z AND a.z+a.height
                AND ray.along-sqrt(greatest(0,a.radius*a.radius-ray.side*ray.side))<=coalesce(dist,1024)
            ORDER BY ray.along-sqrt(greatest(0,a.radius*a.radius-ray.side*ray.side)),a.id LIMIT 1;
            UPDATE doom.actors SET health=greatest(0,health-20) WHERE game=gid AND id=target_id RETURNING * INTO foe;
            IF FOUND AND foe.role='monster' THEN
                PERFORM doom.monster_sound(gid,generation,n,foe.code,CASE WHEN foe.health=0 THEN 'death' ELSE 'pain' END);
            END IF;
            UPDATE doom.games SET ammo=ammo-1,next_shot=n+8 WHERE id=gid;
        END IF;
    END IF;
    IF forward<>0 OR strafe<>0 THEN
        dist := 8/greatest(1,sqrt(forward^2+strafe^2));
        delta := point((facing[0]*forward-facing[1]*strafe)*dist,(facing[1]*forward+facing[0]*strafe)*dist);
        before_pos := player.pos;
        loc := doom.try_move(g.level,player,player.pos+delta,true);
        IF loc.pos IS NOT NULL THEN
            UPDATE doom.actors SET pos=loc.pos,sector=loc.sector,z=loc.z,
                yaw=CASE WHEN write_turn THEN player.yaw ELSE yaw END WHERE game=gid AND id=-1;
            player.pos:=loc.pos; player.sector:=loc.sector; player.z:=loc.z;
            FOR contact IN SELECT l.id,l.special FROM doom.lines l WHERE l.level=g.level AND l.special<>0
                AND box(l.a,l.b) && box(before_pos,loc.pos) AND lseg(l.a,l.b) ?# lseg(before_pos,loc.pos)
                ORDER BY (lseg(l.a,l.b) # lseg(before_pos,loc.pos)) <-> before_pos,l.id LOOP
                PERFORM doom.activate(g,contact.id,'cross');
                IF contact.special IN (52,124) THEN RETURN n; END IF;
                IF contact.special IN (39,97) THEN
                    SELECT pos,sector,z INTO player.pos,player.sector,player.z FROM doom.actors WHERE game=gid AND id=-1;
                    EXIT;
                END IF;
            END LOOP;
        ELSIF write_turn THEN
            UPDATE doom.actors SET yaw=player.yaw WHERE game=gid AND id=-1;
        END IF;
    END IF;
    FOR contact IN DELETE FROM doom.actors a WHERE a.game=gid AND a.role='pickup' AND a.sector=player.sector
        AND a.cell_x BETWEEN floor((player.pos[0]-24)/128)::int AND floor((player.pos[0]+24)/128)::int
        AND a.cell_y BETWEEN floor((player.pos[1]-24)/128)::int AND floor((player.pos[1]+24)/128)::int
        AND a.pos<->player.pos<24 AND abs(a.z-player.z)<player.height RETURNING a.code LOOP
        IF contact.code IN (5,6,13,38,39,40) THEN UPDATE doom.games SET keys=keys | CASE WHEN contact.code IN (5,40) THEN 1
            WHEN contact.code IN (6,39) THEN 2 ELSE 4 END WHERE id=gid;
        ELSIF contact.code IN (2011,2012,2013,2014) THEN UPDATE doom.actors SET health=least(200,health+
            CASE contact.code WHEN 2011 THEN 10 WHEN 2012 THEN 25 WHEN 2013 THEN 100 ELSE 1 END) WHERE game=gid AND id=-1;
        ELSIF contact.code IN (2015,2018,2019) THEN UPDATE doom.games SET armor=least(200,armor+
            CASE contact.code WHEN 2018 THEN 100 WHEN 2019 THEN 200 ELSE 1 END) WHERE id=gid;
        ELSE UPDATE doom.games SET ammo=least(400,ammo+10) WHERE id=gid; END IF;
    END LOOP;
    FOR foe IN SELECT a.* FROM doom.actors a WHERE a.game=gid AND a.role='monster' AND a.health>0 AND a.id%8=n%8
        AND a.awake_at<=n AND box(point(player.pos[0]-320,player.pos[1]-320),point(player.pos[0]+320,player.pos[1]+320)) @> a.pos
        ORDER BY a.id FOR UPDATE OF a LOOP
        delta := player.pos-foe.pos; dist := foe.pos<->player.pos;
        CONTINUE WHEN dist>320 OR dist=0;
        IF sectors IS NULL THEN
            SELECT sector_count,CASE WHEN NOT EXISTS(SELECT FROM doom.movers WHERE game=gid) THEN reject END
            INTO sectors,matrix FROM doom.levels WHERE id=g.level;
        END IF;
        bit_index:=foe.sector::bigint*sectors+player.sector;
        CONTINUE WHEN matrix IS NOT NULL AND foe.sector BETWEEN 0 AND sectors-1 AND player.sector BETWEEN 0 AND sectors-1
            AND (get_byte(matrix,(bit_index/8)::int) & (1 << (bit_index%8)::int))<>0;
        CONTINUE WHEN EXISTS(SELECT FROM doom.trace(g.level,gid,foe.pos,delta,foe.sector,foe.z+32) WHERE blocked);
        IF foe.awake_at=0 THEN
            PERFORM doom.monster_sound(gid,generation,n,foe.code,'sight');
            UPDATE doom.actors SET awake_at=n WHERE game=gid AND id=foe.id;
        END IF;
        IF dist<128 THEN damage:=damage+4;
            PERFORM doom.monster_sound(gid,generation,n,foe.code,'attack');
            UPDATE doom.actors SET awake_at=n+24,yaw=atan2(delta[1],delta[0]) WHERE game=gid AND id=foe.id;
        ELSE
            loc := doom.try_move(g.level,foe,foe.pos+point(delta[0]*4/dist,delta[1]*4/dist));
            IF loc.pos IS NOT NULL THEN UPDATE doom.actors SET pos=loc.pos,z=loc.z,sector=loc.sector,
                yaw=atan2(delta[1],delta[0]) WHERE game=gid AND id=foe.id; END IF;
        END IF;
    END LOOP;
    IF n%32=0 AND EXISTS(SELECT FROM doom.sectors WHERE level=g.level AND id=player.sector AND special IN (4,5,7,11,16))
        THEN damage:=damage+10; END IF;
    IF damage>0 THEN
        UPDATE doom.games SET armor=greatest(0,armor-damage/3) WHERE id=gid AND armor>0;
        UPDATE doom.actors SET health=greatest(0,health-damage+least(g.armor,damage/3)) WHERE game=gid AND id=-1;
    END IF;
    RETURN n;
END;
$$;
