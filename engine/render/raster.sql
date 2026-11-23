-- Pack a block in one expression so PostgreSQL's executor can evaluate the
-- eight independent texture lookups without eight PL/pgSQL iterations.
CREATE FUNCTION doom.gather8(data bytea,base int,mask int,v float8,step float8,i int)
RETURNS bytea LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
RETURN int8send(
    (get_byte(data,base+(floor(v+(i+0)*step)::int & mask))::bigint << 56)
    | (get_byte(data,base+(floor(v+(i+1)*step)::int & mask))::bigint << 48)
    | (get_byte(data,base+(floor(v+(i+2)*step)::int & mask))::bigint << 40)
    | (get_byte(data,base+(floor(v+(i+3)*step)::int & mask))::bigint << 32)
    | (get_byte(data,base+(floor(v+(i+4)*step)::int & mask))::bigint << 24)
    | (get_byte(data,base+(floor(v+(i+5)*step)::int & mask))::bigint << 16)
    | (get_byte(data,base+(floor(v+(i+6)*step)::int & mask))::bigint << 8)
    | (get_byte(data,base+(floor(v+(i+7)*step)::int & mask))::bigint << 0));

-- Column samples are contiguous in WAD patch storage. An affine phase confined
-- to one texel certifies a native slice even at nonintegral scale.
CREATE FUNCTION doom.column_samples(colors bytea,w int,h int,u float8,v float8,dv float8,n int)
RETURNS bytea LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
    col int:=((floor(u)::int%w+w)%w)*h;
    row0 int:=floor(v)::int;
    j int:=((row0%h)+h)%h;
    phase float8:=v-row0;
    last_phase float8:=phase+(n-1)*(dv-1);
    guard float8:=1e-14*(1+abs(v)+n*abs(dv));
    result bytea;
    row_i int;
    at_i int:=0;
BEGIN
    IF n=1 THEN RETURN substring(colors FROM col+j+1 FOR 1); END IF;
    IF n<=h AND ((dv=1 AND phase=0) OR (least(phase,last_phase)>guard AND greatest(phase,last_phase)<1-guard)) THEN
        IF j+n<=h THEN RETURN substring(colors FROM col+j+1 FOR n); END IF;
        RETURN substring(colors FROM col+j+1 FOR h-j)||substring(colors FROM col+1 FOR n-(h-j));
    END IF;
    IF floor(v+(n-1)*dv)=row0 THEN RETURN decode(repeat(encode(substring(colors FROM col+j+1 FOR 1),'hex'),n),'hex'); END IF;
    result:=decode(repeat('00',n),'hex');
    IF (h&(h-1))=0 THEN
        WHILE at_i+8<=n LOOP
            result:=overlay(result PLACING doom.gather8(colors,col,h-1,v,dv,at_i) FROM at_i+1 FOR 8);
            at_i:=at_i+8;
        END LOOP;
        FOR i IN at_i..n-1 LOOP
            result:=set_byte(result,i,get_byte(colors,col+(floor(v+i*dv)::int & (h-1))));
        END LOOP;
    ELSE
        FOR i IN 0..n-1 LOOP
            row_i:=floor(v+i*dv)::int;
            result:=set_byte(result,i,get_byte(colors,col+(row_i%h+h)%h));
        END LOOP;
    END IF;
    RETURN result;
END;
$$;

CREATE FUNCTION doom.flat_index(px float8,py float8,dx float8,dy float8,z float8)
RETURNS int LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
RETURN ((floor(px+dx*z)::bigint & 63) | ((floor(py+dy*z)::bigint & 63)<<6))::int;

CREATE FUNCTION doom.plane_eight(data bytea,px float8,py float8,dx float8,dy float8,depths float8[],i int)
RETURNS bytea LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
RETURN int8send(
    (get_byte(data,doom.flat_index(px,py,dx,dy,depths[i+0]))::bigint << 56)
    | (get_byte(data,doom.flat_index(px,py,dx,dy,depths[i+1]))::bigint << 48)
    | (get_byte(data,doom.flat_index(px,py,dx,dy,depths[i+2]))::bigint << 40)
    | (get_byte(data,doom.flat_index(px,py,dx,dy,depths[i+3]))::bigint << 32)
    | (get_byte(data,doom.flat_index(px,py,dx,dy,depths[i+4]))::bigint << 24)
    | (get_byte(data,doom.flat_index(px,py,dx,dy,depths[i+5]))::bigint << 16)
    | (get_byte(data,doom.flat_index(px,py,dx,dy,depths[i+6]))::bigint << 8)
    | (get_byte(data,doom.flat_index(px,py,dx,dy,depths[i+7]))::bigint << 0));

CREATE TYPE doom.tile AS (w int,h int,pixels bytea,mask bytea,stretched bytea);
CREATE FUNCTION doom.sprite_strokes(p bigint,g bigint,body doom.actors,fx float8,fy float8,far_z float8)
RETURNS SETOF doom.stroke LANGUAGE plpgsql STABLE STRICT AS $$
BEGIN
    RETURN QUERY WITH projected AS (
        SELECT a.id,a.art,im.w,im.h,im.origin_x,im.origin_y,a.z,coalesce(rc.light,s.light) AS light,
            greatest(coalesce(m.floor_z,s.floor_z),a.z+im.origin_y-im.h) AS bottom,
            least(coalesce(m.ceiling_z,s.ceiling_z),a.z+im.origin_y) AS top,
            (a.pos[0]-body.pos[0])*fx+(a.pos[1]-body.pos[1])*fy AS depth,
            (a.pos[0]-body.pos[0])*fy-(a.pos[1]-body.pos[1])*fx AS rightward
        FROM doom.actors a JOIN doom.art im ON im.id=a.art JOIN doom.sectors s ON s.level=p AND s.id=a.sector
        LEFT JOIN doom.room_changes rc ON rc.game=g AND rc.sector=a.sector
        JOIN doom.mesh am ON am.level=p AND am.sector=a.sector
        JOIN doom.mesh camera_room ON camera_room.level=p AND camera_room.sector=body.sector AND camera_room.component=am.component
        LEFT JOIN doom.movers m ON m.game=g AND m.sector=a.sector
        WHERE a.game=g AND a.id<>-1 AND a.health>0
    ), screen AS (
        SELECT *,79.5+(rightward-origin_x)*80/nullif(depth,0) AS left_x,
            79.5+(rightward-origin_x+w)*80/nullif(depth,0) AS right_x,
            greatest(0,least(100,ceil(49.5+(body.z+41-top)*80/nullif(depth,0))))::int AS y0,
            greatest(0,least(100,ceil(49.5+(body.z+41-bottom)*80/nullif(depth,0))))::int AS y1
        FROM projected WHERE depth>0.001 AND depth<=far_z
    )
    SELECT x,y0,y1,4,art,(x-left_x)*depth/80,z+origin_y-body.z-41+(y0-49.5)*depth/80,depth/80,depth,light
    FROM screen,LATERAL generate_series(greatest(0,least(160,ceil(left_x)))::int,
        greatest(-1,least(159,ceil(right_x)-1))::int)x
    WHERE y0<y1;
END;
$$;

CREATE TYPE doom.plane_lut AS (depths float8[],bands bytea);
CREATE TABLE doom.plane_tables (
    level bigint REFERENCES doom.levels ON DELETE CASCADE, distance int, light int, lut doom.plane_lut NOT NULL,
    PRIMARY KEY(level,distance,light)
);
CREATE FUNCTION doom.make_plane_lut(delta float8,light int,bands int,rays float8[])
RETURNS doom.plane_lut LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT ROW(array_agg(z ORDER BY y),decode(string_agg(lpad(to_hex(least(bands,(255-light)/8+floor(z/96)::int)),
        2,'0'),'' ORDER BY y),'hex'))::doom.plane_lut
    FROM unnest(rays) WITH ORDINALITY r(scale,y), LATERAL(SELECT delta*scale AS z) d;
$$;
CREATE FUNCTION doom.compile_plane_tables() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    DELETE FROM doom.plane_tables WHERE level=NEW.id;
    INSERT INTO doom.plane_tables
    SELECT NEW.id,delta,light,doom.make_plane_lut(delta,light,least(32,length(NEW.lighting)/256)-1,s.row_scale)
    FROM (
        SELECT DISTINCT abs(altitude-target) AS delta,room.light
        FROM doom.sectors room JOIN doom.mesh m ON m.level=room.level AND m.sector=room.id,
        LATERAL (SELECT room.floor_z+41 AS altitude UNION
            SELECT near.floor_z+41 FROM unnest(m.edges)e JOIN doom.sectors near ON near.level=NEW.id AND near.id=e.dest) camera,
        LATERAL (VALUES(room.floor_z),(room.ceiling_z)) surface(target)
        WHERE room.level=NEW.id
    ) planes CROSS JOIN doom.screen s;
    RETURN NULL;
END;
$$;
CREATE TRIGGER compile_plane_tables AFTER UPDATE OF revision,lighting ON doom.levels
FOR EACH ROW EXECUTE FUNCTION doom.compile_plane_tables();

CREATE FUNCTION doom.raster(gid bigint,generation bigint,slot bigint,background_only boolean)
RETURNS TABLE(epoch bigint,tic bigint,frame_slot bigint,width int,height int,pixels bytea,shades bytea,scene_depth float8[])
LANGUAGE plpgsql STABLE STRICT SET jit=off SET plan_cache_mode=force_generic_plan AS $$
DECLARE
    p bigint;
    body doom.actors;
    fx float8;
    fy float8;
    sx float8;
    sy float8;
    eye float8;
    at_y int;
    image bytea;
    plane_depths float8[];
    row_scale float8[];
    stroke doom.stroke;
    strokes doom.stroke[];
    world doom.stroke[];
    base_color bytea;
    base_light bytea;
    base_depth float8[];
    horizon float8;
    rev bigint;
    plane_keys int[];
    plane_index int;
    planes doom.plane_lut[];
    plane doom.plane_lut;
    camera_x float8;
    camera_y float8;
    bank doom.tile[];
    first_art int;
    tex doom.tile;
    bands int;
    band int;
    empty_column bytea:=decode(repeat('00',100),'hex');
    colors bytea[]:=array_fill(empty_column,ARRAY[160],ARRAY[0]);
    lights bytea[]:=colors;
    column_data bytea;
    column_light bytea;
    sample bytea;
    prior_art int;
    prior_column int;
    prior_v float8;
    prior_step float8;
    prior_count int;
    prior_sample bytea;
    source_column int;
    opacity bytea;
    level_light int;
    zbuffer float8[]; -- Only allocated for columns with masked surfaces or sprites.
    overlay_columns int[];
    this_x int:=-1;
    has_overlay boolean;
    z float8;
    n int;
    idx int;
    shade_run bytea[];
BEGIN
    SELECT g.epoch,g.tic,g.level INTO STRICT epoch,tic,p FROM doom.games g WHERE g.id=gid;
    SELECT * INTO STRICT body FROM doom.actors WHERE game=gid AND id=-1;
    IF epoch<>generation OR slot<0 THEN RAISE EXCEPTION 'invalid frame generation or slot' USING ERRCODE='22023'; END IF;
    SELECT screen.row_scale,screen.shade_runs INTO row_scale,shade_run FROM doom.screen;
    fx:=cos(body.yaw); fy:=sin(body.yaw); eye:=body.z+41;
    SELECT least(32,length(lighting)/256)-1,revision INTO bands,rev FROM doom.levels WHERE id=p;
    camera_x:=body.pos[0]; camera_y:=-body.pos[1];
    IF NOT background_only THEN
        SELECT c.background,c.illumination,c.depths,c.far_z INTO base_color,base_light,base_depth,horizon
        FROM doom.view_cache c WHERE c.game=gid AND c.revision=rev AND c.sector=body.sector AND c.x=camera_x
            AND c.y=body.pos[1] AND c.yaw=body.yaw AND c.z=body.z AND c.openings=doom.opening_key(gid);
    END IF;
    IF base_color IS NULL THEN
        SELECT array_agg(s) INTO world FROM doom.world_strokes(p,gid,body,fx,fy)s;
        SELECT CASE WHEN sum(y1-y0) FILTER(WHERE kind<3)=16000 THEN max(
            CASE WHEN kind=0 THEN greatest(row_scale[y0+1],row_scale[y1])*abs(eye-v) ELSE depth END
        ) ELSE 'Infinity'::float8 END INTO horizon FROM unnest(world);
    END IF;
    SELECT array_agg(s ORDER BY x,(kind>=3),CASE WHEN kind>=3 THEN -depth END,kind,art,y0) INTO strokes FROM (
        SELECT * FROM unnest(world) UNION ALL
        SELECT * FROM doom.sprite_strokes(p,gid,body,fx,fy,horizon) WHERE NOT background_only
    ) s;
    width:=160; height:=100; frame_slot:=slot;
    IF base_color IS NOT NULL THEN
        IF strokes IS NULL THEN pixels:=base_color; shades:=base_light; RETURN NEXT; RETURN; END IF;
        FOR x IN 0..159 LOOP
            colors[x]:=substring(base_color FROM x*100+1 FOR 100);
            lights[x]:=substring(base_light FROM x*100+1 FOR 100);
        END LOOP;
    ELSIF background_only THEN
        scene_depth:=array_fill('Infinity'::float8,ARRAY[16000]);
    END IF;
    -- Each plane has a single depth and light per scanline, across its entire width.
    SELECT array_agg(key ORDER BY key),array_agg(coalesce(t.lut,doom.make_plane_lut(abs(eye-v),s.light,bands,row_scale)) ORDER BY key)
    INTO plane_keys,planes
    FROM (SELECT DISTINCT v,light,(v::int*256+light) AS key FROM unnest(world) WHERE kind=0) s
    LEFT JOIN doom.plane_tables t ON t.level=p AND t.distance=abs(eye-v) AND t.light=s.light;
    -- Read and detoast only the textures actually present in this view.
    SELECT min(art) INTO first_art FROM unnest(strokes);
    SELECT array_agg(CASE WHEN a.id IS NOT NULL THEN ROW(a.w,a.h,substring(a.pixels FROM 1),
        substring(a.mask FROM 1),CASE WHEN used.stretch THEN substring(a.stretched FROM 1) END)::doom.tile END ORDER BY id_range) INTO bank
    FROM generate_series(first_art,(SELECT max(art) FROM unnest(strokes)))id_range
    LEFT JOIN (SELECT art,bool_or(kind=1 AND dv BETWEEN 0.46 AND 0.54) AS stretch FROM unnest(strokes) GROUP BY art) used ON used.art=id_range
    LEFT JOIN doom.art a ON a.id=used.art;
    SELECT array_agg(x) INTO overlay_columns FROM (SELECT DISTINCT x FROM unnest(strokes) WHERE kind>=3) overlay_cols;
    FOREACH stroke IN ARRAY coalesce(strokes,'{}') LOOP
        IF stroke.x<>this_x THEN
            IF this_x>=0 THEN
                colors[this_x]:=column_data; lights[this_x]:=column_light;
                IF background_only THEN scene_depth[1+100*this_x:100*(this_x+1)]:=zbuffer; END IF;
            END IF;
            this_x:=stroke.x; column_data:=colors[this_x]; column_light:=lights[this_x];
            has_overlay:=background_only OR coalesce(this_x=ANY(overlay_columns),false);
            IF has_overlay THEN
                zbuffer:=array_fill('Infinity'::float8,ARRAY[100],ARRAY[0]);
                IF base_depth IS NOT NULL THEN zbuffer[0:99]:=base_depth[100*this_x+1:100*(this_x+1)]; END IF;
            END IF;
            sx:=fx+fy*(this_x-79.5)/80; sy:=fy-fx*(this_x-79.5)/80;
        END IF;
        tex:=bank[stroke.art-first_art+1];
        n:=stroke.y1-stroke.y0; level_light:=(255-stroke.light)/8;
        IF stroke.kind=0 THEN
            plane_index:=array_position(plane_keys,stroke.v::int*256+stroke.light);
            plane:=planes[plane_index];
            column_light:=overlay(column_light PLACING substring(plane.bands FROM stroke.y0+1 FOR n) FROM stroke.y0+1 FOR n);
            IF has_overlay THEN zbuffer[stroke.y0:stroke.y1-1]:=plane.depths[stroke.y0+1:stroke.y1]; END IF;
            IF tex.pixels IS NOT NULL THEN
                at_y:=stroke.y0; image:=tex.pixels; plane_depths:=plane.depths;
                WHILE at_y+8<=stroke.y1 LOOP
                    sample:=doom.plane_eight(image,camera_x,camera_y,sx,-sy,plane_depths,at_y+1);
                    column_data:=overlay(column_data PLACING sample FROM at_y+1 FOR 8);
                    at_y:=at_y+8;
                END LOOP;
                FOR y IN at_y..stroke.y1-1 LOOP
                    z:=plane_depths[y+1];
                    idx:=(floor(camera_x+sx*z)::bigint & 63)+64*(floor(camera_y-sy*z)::bigint & 63);
                    column_data:=set_byte(column_data,y,get_byte(image,idx));
                END LOOP;
            END IF;
        ELSE
            IF stroke.kind>=3 AND NOT (stroke.depth < ANY(zbuffer[stroke.y0:stroke.y1-1])) THEN CONTINUE; END IF;
            band:=CASE WHEN stroke.kind=2 THEN 0 ELSE least(bands,level_light+floor(stroke.depth/96)::int) END;
            source_column:=floor(stroke.u)::int;
            IF stroke.kind=1 AND prior_art=stroke.art AND prior_column=source_column AND prior_v=stroke.v
               AND prior_step=stroke.dv AND prior_count=n THEN
                sample:=prior_sample;
            ELSIF tex.stretched IS NOT NULL AND stroke.kind=1 AND stroke.dv BETWEEN 0.46 AND 0.54 THEN
                sample:=doom.column_samples(tex.stretched,tex.w,tex.h*2,stroke.u,2*stroke.v,2*stroke.dv,n);
            ELSE
                sample:=coalesce(doom.column_samples(tex.pixels,tex.w,tex.h,stroke.u,stroke.v,stroke.dv,n),substring(empty_column FOR n));
            END IF;
            IF stroke.kind=1 THEN
                prior_art:=stroke.art; prior_column:=source_column; prior_v:=stroke.v;
                prior_step:=stroke.dv; prior_count:=n; prior_sample:=sample;
            END IF;
            IF stroke.kind<3 THEN
                column_data:=overlay(column_data PLACING sample FROM stroke.y0+1 FOR n);
                column_light:=overlay(column_light PLACING substring(shade_run[band+1] FOR n) FROM stroke.y0+1 FOR n);
                IF has_overlay THEN FOR y IN stroke.y0..stroke.y1-1 LOOP zbuffer[y]:=stroke.depth; END LOOP; END IF;
            ELSE
                opacity:=doom.column_samples(tex.mask,tex.w,tex.h,stroke.u,stroke.v,stroke.dv,n);
                FOR i IN 0..n-1 LOOP
                    idx:=stroke.y0+i;
                    IF stroke.depth<zbuffer[idx] AND (opacity IS NULL OR get_byte(opacity,i)<>0)
                        AND (stroke.kind<>3 OR stroke.v+i*stroke.dv>=0 AND stroke.v+i*stroke.dv<tex.h) THEN
                        column_data:=set_byte(column_data,idx,get_byte(sample,i)); column_light:=set_byte(column_light,idx,band);
                        zbuffer[idx]:=stroke.depth;
                    END IF;
                END LOOP;
            END IF;
        END IF;
    END LOOP;
    IF this_x>=0 THEN
                colors[this_x]:=column_data; lights[this_x]:=column_light;
                IF background_only THEN scene_depth[1+100*this_x:100*(this_x+1)]:=zbuffer; END IF;
            END IF;
    SELECT string_agg(c,''::bytea ORDER BY i),string_agg(l,''::bytea ORDER BY i) INTO pixels,shades
    FROM unnest(colors,lights) WITH ORDINALITY b(c,l,i);
    RETURN NEXT;
END;
$$;

CREATE FUNCTION doom.frame(gid bigint,generation bigint,slot bigint DEFAULT 0)
RETURNS TABLE(epoch bigint,tic bigint,frame_slot bigint,width int,height int,pixels bytea,shades bytea)
LANGUAGE sql STABLE AS $$
    SELECT r.epoch,r.tic,r.frame_slot,r.width,r.height,r.pixels,r.shades FROM doom.raster(gid,generation,slot,false)r;
$$;

CREATE FUNCTION doom.frame_palette(gid bigint) RETURNS bytea LANGUAGE sql STABLE STRICT AS $$
    SELECT string_agg(substring(l.palette FROM 1+3*get_byte(l.lighting,i) FOR 3),''::bytea ORDER BY i)
    FROM doom.games g JOIN doom.levels l ON l.id=g.level,
        LATERAL generate_series(0,least(length(l.lighting),32*256)-1)i WHERE g.id=gid;
$$;
COMMENT ON FUNCTION doom.frame(bigint,bigint,bigint) IS
'Column-major 8-bit pixels and shades. At (x,y), i=x*height+y. RGB starts at 3*(256*shades[i]+pixels[i]) in frame_palette(game).';
