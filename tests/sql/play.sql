BEGIN;
DO $$
DECLARE
    p bigint;
    g bigint;
    sprite int;
    other_game bigint;
    other_key text;
    saved doom.actors;
    pic bytea;
    lighting bytea;
    key text;
    packet record;
    known text[];
    reference bytea;
BEGIN
    SELECT decode(string_agg(lpad(to_hex(i),2,'0'),'' ORDER BY i),'hex') INTO lighting FROM generate_series(0,255)i;
    INSERT INTO doom.levels(name,palette,lighting,sector_count)
    VALUES('FIXTURE',decode(repeat('000000',256),'hex'),lighting,2) RETURNING id INTO p;
    INSERT INTO doom.sectors VALUES(p,0,0,80,'F','C',255,0,0),(p,1,0,80,'F','C',255,0,0);
    INSERT INTO doom.art(level,kind,name,w,h,pixels)
    VALUES(p,'flat','F',64,64,decode(repeat('04',4096),'hex')),(p,'flat','C',64,64,decode(repeat('05',4096),'hex')),
        (p,'wall','W',1,1,decode('37','hex')),(p,'wall','D',1,1,decode('99','hex'));
    INSERT INTO doom.art(level,kind,name,w,h,origin_x,origin_y,pixels,mask)
    VALUES(p,'sprite','POSSA1',16,64,8,64,decode(repeat('31',1024),'hex'),
        decode(repeat(repeat('ff',23)||'00'||repeat('ff',40),16),'hex')) RETURNING id INTO sprite;
    INSERT INTO doom.sides VALUES(p,0,0,0,0,NULL,NULL,'W'),(p,1,0,0,0,'D',NULL,NULL),
        (p,2,1,0,0,'D',NULL,NULL),(p,3,1,0,0,NULL,NULL,'W');
    INSERT INTO doom.lines VALUES
        (p,0,point(-128,80),point(64,80),0,NULL,1,0,0),
        (p,1,point(64,80),point(64,-80),1,2,4,1,0),
        (p,2,point(64,-80),point(-128,-80),0,NULL,1,0,0),
        (p,3,point(-128,-80),point(-128,80),0,NULL,1,0,0),
        (p,4,point(64,80),point(160,80),3,NULL,1,0,0),
        (p,5,point(160,80),point(160,-80),3,NULL,1,0,0),
        (p,6,point(160,-80),point(64,-80),3,NULL,1,0,0);
    INSERT INTO doom.spawns VALUES(p,0,point(0,0),0,1,7),(p,1,point(100,0),180,3004,7);
    PERFORM doom.compile_level(p); UPDATE doom.levels SET ready=true WHERE id=p;
    SELECT game_id INTO STRICT g FROM doom.new_game(p);
    SELECT pixels,token INTO pic,key FROM doom.poll_frame(g,1,1);
    SELECT game_id INTO other_game FROM doom.new_game(p);
    SELECT token INTO other_key FROM doom.poll_frame(other_game,1,1);
    UPDATE doom.actors SET game=other_game,id=77 WHERE game=g AND id=1;
    ASSERT (SELECT token<>key FROM doom.poll_frame(g,1,1,key));
    ASSERT (SELECT token<>other_key FROM doom.poll_frame(other_game,1,1,other_key));
    UPDATE doom.actors SET game=g,id=1 WHERE game=other_game AND id=77;
    ASSERT (SELECT pixels IS NULL FROM doom.poll_frame(other_game,1,1,other_key));
    DELETE FROM doom.games WHERE id=other_game;
    DELETE FROM doom.actors WHERE game=g AND id=1 RETURNING * INTO saved;
    ASSERT (SELECT token<>key FROM doom.poll_frame(g,1,1,key));
    INSERT INTO doom.actors(game,id,sector,pos,z,yaw,code,role,art,health,radius,height,awake_at)
    SELECT saved.game,saved.id,saved.sector,saved.pos,saved.z,saved.yaw,saved.code,saved.role,saved.art,
        saved.health,saved.radius,saved.height,saved.awake_at;
    ASSERT (SELECT pixels IS NULL FROM doom.poll_frame(g,1,1,key)),'restoring an actor must restore the scene signature';

    SELECT * INTO packet FROM doom.poll_tiles(g,1,1,NULL,NULL);
    ASSERT cardinality(packet.tiles)=20 AND packet.pixels=pic;
    known:=packet.hashes;
    SELECT * INTO packet FROM doom.poll_tiles(g,1,2,key,known);
    ASSERT packet.pixels IS NULL AND packet.tiles='{}'::int[];
    known[2]:=NULL;
    SELECT * INTO packet FROM doom.poll_tiles(g,1,2,key,known);
    ASSERT packet.tiles=ARRAY[1] AND packet.pixels=substring(pic FROM 801 FOR 800);
    PERFORM doom.anchor_view(g);
    ASSERT (SELECT pixels=pic FROM doom.frame(g,1,1)),'cached geometry changed the scene';
    UPDATE doom.actors SET pos=point(100,13) WHERE game=g AND id=1;
    SELECT pixels INTO reference FROM doom.frame(g,1,1);
    DELETE FROM doom.view_cache WHERE game=g;
    ASSERT (SELECT pixels=reference FROM doom.frame(g,1,1)),'moving sprite was clipped differently against the cached depth buffer';
    UPDATE doom.actors SET pos=point(100,0) WHERE game=g AND id=1;
    PERFORM doom.anchor_view(g);
    ASSERT length(pic)=16000;
    ASSERT get_byte(pic,8050)=55 AND get_byte(pic,8051)=49,'masked sprite must show both the far wall and its opaque texel';
    ASSERT get_byte(pic,8099)=4 AND get_byte(pic,8000)=5,'floor and ceiling';
    ASSERT (SELECT pixels IS NULL FROM doom.poll_frame(g,1,2,key));
    INSERT INTO doom.art(level,kind,name,w,h,pixels)
    SELECT p,'wall','SKY1',1,100,decode(string_agg(lpad(to_hex(y),2,'0'),'' ORDER BY y),'hex')
    FROM generate_series(0,99)y;
    UPDATE doom.sectors SET ceiling_z=52,ceiling_tex=CASE WHEN id=1 THEN 'F_SKY1' ELSE 'C' END WHERE level=p;
    ASSERT (SELECT get_byte(pixels,8038)=38 FROM doom.frame(g,1,2)),'clipped sky must retain its screen row';
    UPDATE doom.sectors SET ceiling_z=80,ceiling_tex='C' WHERE level=p;
    UPDATE doom.sectors SET ceiling_z=0 WHERE level=p AND id=1;
    SELECT pixels,token INTO pic,key FROM doom.poll_frame(g,1,3,key);
    ASSERT get_byte(pic,8050)=153 AND get_byte(pic,8051)=153,'closed portal must hide sprites';
    UPDATE doom.actors SET yaw=2*pi() WHERE game=g AND id=-1;
    ASSERT doom.tick(g,1,1,1,0,0,false,false)=1;
    ASSERT (SELECT yaw=2*pi() FROM doom.actors WHERE game=g AND id=-1),'a move without a turn changed edited yaw';
    UPDATE doom.actors SET yaw=0 WHERE game=g AND id=-1;
    ASSERT doom.tick(g,1,1,1,0,0,false,false)=1;
    ASSERT (SELECT pos~=point(8,0) FROM doom.actors WHERE game=g AND id=-1),'duplicate input moved twice';
    BEGIN PERFORM doom.tick(g,1,1,-1,0,0,false,false); RAISE EXCEPTION 'accepted conflicting input';
    EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
    BEGIN PERFORM doom.tick(g,1,3,1,0,0,false,false); RAISE EXCEPTION 'accepted an input gap';
    EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
    ASSERT doom.tick(g,1,2,0,0,0,true,false)=2;
    ASSERT (SELECT target=76 FROM doom.movers WHERE game=g AND sector=1);
    PERFORM doom.tick(g,1,i,0,0,0,false,false) FROM generate_series(3,35)i;
    ASSERT (SELECT ceiling_z=66 FROM doom.movers WHERE game=g AND sector=1);
    PERFORM doom.tick(g,1,36,0,0,0,false,true);
    ASSERT (SELECT health=0 FROM doom.actors WHERE game=g AND id=1),'hitscan missed the monster through the open doorway';
    SELECT pixels INTO pic FROM doom.frame(g,1,4);
    ASSERT get_byte(pic,8051)=55;
    UPDATE doom.lines SET a=point(24,80),b=point(24,-80),back=NULL,front=0 WHERE level=p AND id=1;
    ASSERT EXISTS(SELECT FROM doom.trace(p,g,point(8,0),point(32,0),0,41) WHERE line=1 AND t=0.5 AND blocked);
    ASSERT (SELECT get_byte(pixels,8000)=55 FROM doom.frame(g,1,5)),'wall edit did not reach the renderer';
    UPDATE doom.lines SET special=11 WHERE level=p AND id=1;
    PERFORM doom.tick(g,1,37,0,0,0,true,false);
    ASSERT (SELECT finished FROM doom.game_status(g)) AND doom.tick(g,1,38,1,0,0,false,false)=37;
END;
$$;
ROLLBACK;
