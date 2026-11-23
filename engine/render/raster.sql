CREATE TYPE doom.tile AS (w int,h int,pixels bytea,mask bytea,stretched bytea,quads bytea,quad_start int,column_ids int[],posts doom.sprite_posts);
CREATE FUNCTION doom.sprite_strokes(p bigint,g bigint,body doom.actors,fx float8,fy float8,far_z float8)
RETURNS SETOF doom.stroke LANGUAGE sql STABLE AS $$
    WITH visible_actors AS MATERIALIZED (
        SELECT a.sector,a.art,a.z,im.h,im.origin_y,loc.depth,
            79.5+(loc.rightward-im.origin_x)*80/loc.depth AS left_x,
            79.5+(loc.rightward-im.origin_x+im.w)*80/loc.depth AS right_x
        FROM doom.actors a JOIN doom.art im ON im.id=a.art,
        LATERAL (SELECT (a.pos[0]-body.pos[0])*fx+(a.pos[1]-body.pos[1])*fy AS depth,
                        (a.pos[0]-body.pos[0])*fy-(a.pos[1]-body.pos[1])*fx AS rightward) loc
        WHERE a.game=g AND a.id<>-1 AND a.health>0 AND loc.depth>0.001 AND loc.depth<=far_z
          AND 79.5+(loc.rightward-im.origin_x)*80/nullif(loc.depth,0)<=159
          AND 79.5+(loc.rightward-im.origin_x+im.w)*80/nullif(loc.depth,0)>0
    ), clipped AS (
        SELECT a.*,coalesce(rc.light,s.light) AS light,
            greatest(coalesce(m.floor_z,s.floor_z),a.z+a.origin_y-a.h) AS bottom,
            least(coalesce(m.ceiling_z,s.ceiling_z),a.z+a.origin_y) AS top
        FROM visible_actors a JOIN doom.sectors s ON s.level=p AND s.id=a.sector
        LEFT JOIN doom.room_changes rc ON rc.game=g AND rc.sector=a.sector
        JOIN doom.mesh am ON am.level=p AND am.sector=a.sector
        JOIN doom.mesh camera_room ON camera_room.level=p AND camera_room.sector=body.sector AND camera_room.component=am.component
        LEFT JOIN doom.movers m ON m.game=g AND m.sector=a.sector
    ), screen AS (
        SELECT *,greatest(0,least(100,ceil(49.5+(body.z+41-top)*80/depth)))::int AS y0,
            greatest(0,least(100,ceil(49.5+(body.z+41-bottom)*80/depth)))::int AS y1 FROM clipped
    )
    SELECT x,y0,y1,4,art,(x-left_x)*depth/80,z+origin_y-body.z-41+(y0-49.5)*depth/80,depth/80,depth,light
    FROM screen,LATERAL generate_series(greatest(0,ceil(left_x))::int,least(159,ceil(right_x)-1)::int)x
    WHERE y0<y1;
$$;

CREATE FUNCTION doom.raster(gid bigint,generation bigint,slot bigint,background_only boolean)
RETURNS TABLE(epoch bigint,tic bigint,frame_slot bigint,width int,height int,pixels bytea,shades bytea,scene_depth float8[])
LANGUAGE plpgsql STABLE STRICT SET jit=off SET plan_cache_mode=force_generic_plan AS $$
DECLARE
    p bigint;
    body doom.actors;
    fx float8;
    fy float8;

    eye float8;
    flat_colors bytea[];
    row_scale float8[];
    stroke doom.stroke;
    strokes doom.stroke[];
    world doom.stroke[];
    runs doom.wall_run[];
    run_columns int;
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
    art_ids int[];
    sprites doom.stroke[];
    has_masks boolean;
    full_wall boolean:=false;
    plane_area int;
    dense_flats boolean;
    sx float8; sy float8;
    sparse_tex int;
    image bytea;
    solid_art int;
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
    prior_top int;
    prior_anchor float8;
    prior_low float8;
    prior_high float8;
    cuts float8[];
    bucket int;
    anchor float8;
    guard float8;
    quad_offsets smallint[];
    last_material int;
    prior_sample bytea;
    source_column int;
    runs_start int;
    runs_end int;
    span int4range;
    low_i int;
    high_i int;
    opacity bytea;
    level_light int;
    zbuffer float8[];
    overlay_columns int[];
    this_x int:=-1;
    has_overlay boolean;
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
    SELECT w.cuts,w.quads INTO cuts,quad_offsets FROM doom.wall_scales w;
    camera_x:=body.pos[0]; camera_y:=-body.pos[1];
    IF NOT background_only THEN
        SELECT c.background,c.illumination,c.depths,c.far_z INTO base_color,base_light,base_depth,horizon
        FROM doom.view_cache c WHERE c.game=gid AND c.revision=rev AND c.sector=body.sector AND c.x=camera_x
            AND c.y=body.pos[1] AND c.yaw=body.yaw AND c.z=body.z AND c.openings=doom.opening_key(gid);
    END IF;
    IF base_color IS NULL THEN
        SELECT v.strokes,v.runs INTO world,runs FROM doom.project_world(p,gid,body,fx,fy)v;
        IF runs IS NOT NULL AND world IS NULL AND NOT background_only THEN
            SELECT sum((projection).hi-(projection).lo+1),min(((projection).wall).mid_id),
                min(((projection).wall).mid_id)=max(((projection).wall).mid_id),
                max(1/least((projection).inv0+(projection).lo*(projection).inv_step,
                            (projection).inv0+(projection).hi*(projection).inv_step))
            INTO run_columns,solid_art,full_wall,horizon FROM unnest(runs);
            full_wall:=full_wall AND run_columns=160;
        END IF;
        IF runs IS NOT NULL AND NOT full_wall THEN
            world:=world||ARRAY(SELECT s FROM doom.wall_rays(runs)s);
            runs:=NULL;
        END IF;
        IF NOT full_wall THEN
            SELECT CASE WHEN sum(y1-y0) FILTER(WHERE kind<3)=16000 THEN max(
                CASE WHEN kind=0 THEN greatest(row_scale[y0+1],row_scale[y1])*abs(eye-v) ELSE depth END
            ) ELSE 'Infinity'::float8 END, bool_or(kind>=3),sum(y1-y0) FILTER(WHERE kind=0),
            count(*)=160 AND bool_and(kind=1 AND y0=0 AND y1=100) AND count(art)=160 AND min(art)=max(art),min(art)
            INTO horizon,has_masks,plane_area,full_wall,solid_art FROM unnest(world);
        END IF;
    END IF;
    IF NOT background_only THEN
        SELECT array_agg(s) INTO sprites FROM doom.sprite_strokes(p,gid,body,fx,fy,horizon)s;
    END IF;
    IF runs IS NOT NULL AND sprites IS NOT NULL THEN
        world:=ARRAY(SELECT s FROM doom.wall_rays(runs)s);
        runs:=NULL;
    END IF;
    full_wall:=full_wall AND sprites IS NULL AND NOT background_only;
    -- Small exposed plane fragments cost less to sample than a screen transpose.
    dense_flats:=plane_area>=10000;
    IF dense_flats THEN
        flat_colors:=doom.flat_background(world,camera_x,camera_y,fx,fy,eye,row_scale);
        colors[0:159]:=flat_colors;
    END IF;
    IF has_masks OR sprites IS NOT NULL THEN
        SELECT array_agg(s ORDER BY x,(kind>=3),CASE WHEN kind>=3 THEN -depth END,kind,art,y0) INTO strokes
        FROM unnest(world||sprites)s;
    ELSIF background_only THEN
        SELECT array_agg(s ORDER BY x) INTO strokes FROM unnest(world)s;
    ELSE
        -- Opaque portal strokes never overlap.
        strokes:=world;
    END IF;
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
    -- Depth and light are constant across each scanline of a plane.
    SELECT array_agg(key ORDER BY key),array_agg(coalesce(t.lut,doom.make_plane_lut(abs(eye-v),s.light,bands,row_scale)) ORDER BY key)
    INTO plane_keys,planes
    FROM (SELECT DISTINCT v,light,(v::int*256+light) AS key FROM unnest(world) WHERE kind=0) s
    LEFT JOIN doom.plane_tables t ON t.level=p AND t.distance=abs(eye-v) AND t.light=s.light;
    IF full_wall THEN
        SELECT a.w,a.h,substring(a.pixels FROM 1),a.column_ids INTO tex.w,tex.h,tex.pixels,tex.column_ids
        FROM doom.art a WHERE a.id=solid_art;
        WITH columns AS MATERIALIZED (
            SELECT q.x,coalesce(tex.column_ids[1+c.col],c.col) AS col,q.v,q.dv,
                round(q.v+49.5*q.dv) AS origin,width_bucket(q.dv,cuts) AS bin,
                1e-12*(1+abs(q.v)+100*abs(q.dv)) AS margin,
                least(bands,(255-q.light)/8+floor(q.depth/96)::int) AS band
            FROM (SELECT * FROM unnest(world) UNION ALL SELECT * FROM doom.wall_rays(runs)) q,
                LATERAL(SELECT ((floor(q.u)::int%tex.w)+tex.w)%tex.w AS col)c
        ), bounds AS (
            SELECT min(col) AS lo,max(col) AS hi FROM columns WHERE dv<2.0/3
        ), atlas AS MATERIALIZED (
            SELECT lo,substring(a.quads FROM 1+16*tex.h*lo FOR 16*tex.h*(1+hi-lo)) AS data
            FROM bounds,doom.art a WHERE a.id=solid_art
        ), requests AS (
            SELECT x,col,origin,v,dv,CASE WHEN atlas.data IS NOT NULL AND dv<2.0/3 AND v=origin-49.5*dv
                AND dv>cuts[bin]+margin AND dv<cuts[bin+1]-margin THEN bin END AS bin FROM columns,atlas
        ), groups AS (
            SELECT col,origin,bin,min(v) AS v,min(dv) AS dv,array_agg(x) AS xs FROM requests
            GROUP BY col,origin,bin,CASE WHEN bin IS NULL THEN v END,CASE WHEN bin IS NULL THEN dv END
        ), sampled AS MATERIALIZED (
            SELECT xs,CASE WHEN bin IS NULL THEN doom.column_samples(tex.pixels,tex.w,tex.h,col,v,dv,100)
                ELSE doom.wall_strip(atlas.data,16*tex.h*(col-atlas.lo),16*((origin::bigint & (tex.h-1))::int),
                    16*tex.h-1,quad_offsets,1+(bin-1)*25) END AS strip FROM groups,atlas
        )
        SELECT (SELECT string_agg(strip,''::bytea ORDER BY x) FROM sampled,unnest(xs)x),
            (SELECT string_agg(shade_run[columns.band+1],''::bytea ORDER BY x) FROM columns)
        INTO pixels,shades;
        RETURN NEXT; RETURN;
    ELSE
        SELECT array_agg(a.id ORDER BY a.id),array_agg(ROW(a.w,a.h,substring(a.pixels FROM 1),
            CASE WHEN used.masked THEN substring(a.mask FROM 1) END,
            CASE WHEN used.stretch THEN substring(a.stretched FROM 1) END,
            CASE WHEN used.lo IS NOT NULL THEN substring(a.quads FROM 1+16*a.h*slice.lo FOR 16*a.h*(1+slice.hi-slice.lo)) END,slice.lo,NULL,a.posts)::doom.tile ORDER BY a.id) INTO art_ids,bank
        FROM (SELECT art,bool_or(s.kind>=3) AS masked,bool_or(s.kind=1 AND dv BETWEEN 0.46 AND 0.54) AS stretch,
            min(col) FILTER(WHERE ruler) AS lo,max(col) FILTER(WHERE ruler) AS hi
            FROM unnest(strokes)s,
                LATERAL(SELECT floor(s.u)::int AS col,s.kind=1 AND dv<2.0/3 AND y1-y0>=40 AS ruler)c
            WHERE s.kind>0 OR NOT dense_flats GROUP BY art) used
        JOIN doom.art a ON a.id=used.art
        CROSS JOIN LATERAL (SELECT CASE WHEN floor(used.lo::float8/a.w)=floor(used.hi::float8/a.w)
                THEN ((used.lo%a.w)+a.w)%a.w ELSE 0 END AS lo,
            CASE WHEN floor(used.lo::float8/a.w)=floor(used.hi::float8/a.w)
                THEN ((used.hi%a.w)+a.w)%a.w ELSE a.w-1 END AS hi) slice;
    END IF;
    IF has_masks OR sprites IS NOT NULL THEN
        SELECT array_agg(DISTINCT x) INTO overlay_columns FROM unnest(strokes) WHERE kind>=3;
    END IF;
    FOREACH stroke IN ARRAY coalesce(strokes,'{}') LOOP
        IF stroke.x<>this_x THEN
            IF this_x>=0 THEN
                colors[this_x]:=column_data; lights[this_x]:=column_light;
                IF background_only THEN scene_depth[1+100*this_x:100*(this_x+1)]:=zbuffer; END IF;
            END IF;
            this_x:=stroke.x; column_data:=colors[this_x]; column_light:=lights[this_x];
            has_overlay:=background_only OR coalesce(this_x=ANY(overlay_columns),false);
            IF NOT dense_flats THEN
                sx:=fx+fy*(this_x-79.5)/80; sy:=fy-fx*(this_x-79.5)/80;
            END IF;
            IF has_overlay THEN
                zbuffer:=array_fill('Infinity'::float8,ARRAY[100],ARRAY[0]);
                IF base_depth IS NOT NULL THEN zbuffer[0:99]:=base_depth[100*this_x+1:100*(this_x+1)]; END IF;
            END IF;
        END IF;

        n:=stroke.y1-stroke.y0; level_light:=(255-stroke.light)/8;
        IF stroke.kind=0 THEN
            plane_index:=array_position(plane_keys,stroke.v::int*256+stroke.light);
            plane:=planes[plane_index];
            column_light:=overlay(column_light PLACING substring(plane.bands FROM stroke.y0+1 FOR n) FROM stroke.y0+1 FOR n);
            IF has_overlay THEN zbuffer[stroke.y0:stroke.y1-1]:=plane.depths[stroke.y0+1:stroke.y1]; END IF;
            IF NOT dense_flats AND stroke.art IS NOT NULL THEN
                IF sparse_tex IS DISTINCT FROM stroke.art THEN
                    image:=(bank[array_position(art_ids,stroke.art)]).pixels;
                    sparse_tex:=stroke.art;
                END IF;
                sample:=doom.plane_strip(image,camera_x,camera_y,sx,-sy,plane.depths,stroke.y0,stroke.y1);
                column_data:=overlay(column_data PLACING sample FROM stroke.y0+1 FOR n);
            END IF;

        ELSE
            IF last_material IS DISTINCT FROM stroke.art OR stroke.art IS NULL THEN
                tex:=bank[array_position(art_ids,stroke.art)]; last_material:=stroke.art;
            END IF;
            IF stroke.kind>=3 AND NOT (stroke.depth < ANY(zbuffer[stroke.y0:stroke.y1-1])) THEN CONTINUE; END IF;
            band:=CASE WHEN stroke.kind=2 THEN 0 ELSE least(bands,level_light+floor(stroke.depth/96)::int) END;
            source_column:=floor(stroke.u)::int;
            IF stroke.kind=4 AND (tex.posts).offsets IS NOT NULL AND stroke.dv>0
                AND stroke.v>=0 AND stroke.v+(n-1)*stroke.dv<tex.h THEN
                source_column:=((source_column%tex.w)+tex.w)%tex.w;
                runs_start:=(tex.posts).offsets[1+source_column];
                runs_end:=(tex.posts).offsets[2+source_column]-1;
                sample:=NULL;
                FOR k IN runs_start..runs_end LOOP
                    span:=(tex.posts).runs[k];
                    low_i:=doom.post_row(lower(span),stroke.v,stroke.dv,n);
                    high_i:=doom.post_row(upper(span),stroke.v,stroke.dv,n);
                    CONTINUE WHEN low_i>=high_i OR NOT (stroke.depth < ANY(zbuffer[stroke.y0+low_i:stroke.y0+high_i-1]));
                    -- Starting at the post instead of the stroke can round to a different texel.
                    IF sample IS NULL THEN sample:=doom.column_samples(tex.pixels,tex.w,tex.h,stroke.u,stroke.v,stroke.dv,n); END IF;
                    IF stroke.depth < ALL(zbuffer[stroke.y0+low_i:stroke.y0+high_i-1]) THEN
                        column_data:=overlay(column_data PLACING substring(sample FROM low_i+1 FOR high_i-low_i) FROM stroke.y0+low_i+1 FOR high_i-low_i);
                        column_light:=overlay(column_light PLACING substring(shade_run[band+1] FOR high_i-low_i) FROM stroke.y0+low_i+1 FOR high_i-low_i);
                        zbuffer[stroke.y0+low_i:stroke.y0+high_i-1]:=array_fill(stroke.depth,ARRAY[high_i-low_i]);
                    ELSE
                        FOR i IN low_i..high_i-1 LOOP
                            idx:=stroke.y0+i;
                            IF stroke.depth<zbuffer[idx] THEN
                                column_data:=set_byte(column_data,idx,get_byte(sample,i)); column_light:=set_byte(column_light,idx,band);
                                zbuffer[idx]:=stroke.depth;
                            END IF;
                        END LOOP;
                    END IF;
                END LOOP;
                CONTINUE;
            END IF;
            IF stroke.kind=1 THEN
                anchor:=round(stroke.v-(stroke.y0-49.5)*stroke.dv);
                guard:=1e-12*(1+abs(stroke.v)+n*abs(stroke.dv));
                IF prior_art=stroke.art AND prior_column=source_column AND prior_count=n
                    AND ((prior_v=stroke.v AND prior_step=stroke.dv) OR
                        (prior_top=stroke.y0 AND prior_anchor=anchor AND stroke.v=anchor+(stroke.y0-49.5)*stroke.dv
                        AND stroke.dv>prior_low+guard AND stroke.dv<prior_high-guard)) THEN
                    sample:=prior_sample;
                ELSE
                    prior_art:=stroke.art; prior_column:=source_column; prior_top:=stroke.y0;
                    prior_anchor:=anchor; prior_v:=stroke.v; prior_step:=stroke.dv; prior_count:=n;
                    prior_low:=NULL; prior_high:=NULL;
                    IF stroke.dv<2 AND stroke.v=anchor+(stroke.y0-49.5)*stroke.dv THEN
                        bucket:=width_bucket(stroke.dv,cuts);
                        IF stroke.dv>cuts[bucket]+guard AND stroke.dv<cuts[bucket+1]-guard THEN
                            prior_low:=cuts[bucket]; prior_high:=cuts[bucket+1];
                        END IF;
                    END IF;
                    IF tex.quads IS NOT NULL AND n>=40 AND stroke.dv<2.0/3 AND prior_low IS NOT NULL THEN
                        sample:=substring(doom.wall_strip(tex.quads,16*tex.h*((((source_column%tex.w)+tex.w)%tex.w)-tex.quad_start),
                            16*((anchor::bigint & (tex.h-1))::int),16*tex.h-1,quad_offsets,1+(bucket-1)*25)
                            FROM stroke.y0+1 FOR n);
                    ELSIF tex.stretched IS NOT NULL AND stroke.dv BETWEEN 0.46 AND 0.54 THEN
                        sample:=doom.column_samples(tex.stretched,tex.w,tex.h*2,stroke.u,2*stroke.v,2*stroke.dv,n);
                    ELSE
                        sample:=coalesce(doom.column_samples(tex.pixels,tex.w,tex.h,stroke.u,stroke.v,stroke.dv,n),substring(empty_column FOR n));
                    END IF;
                    prior_sample:=sample;
                END IF;
            ELSE
                sample:=coalesce(doom.column_samples(tex.pixels,tex.w,tex.h,stroke.u,stroke.v,stroke.dv,n),substring(empty_column FOR n));
            END IF;
            IF stroke.kind<3 THEN
                column_data:=overlay(column_data PLACING sample FROM stroke.y0+1 FOR n);
                column_light:=overlay(column_light PLACING substring(shade_run[band+1] FOR n) FROM stroke.y0+1 FOR n);
                IF has_overlay THEN zbuffer[stroke.y0:stroke.y1-1]:=array_fill(stroke.depth,ARRAY[n]); END IF;
            ELSE
                opacity:=doom.column_samples(tex.mask,tex.w,tex.h,stroke.u,stroke.v,stroke.dv,n);
                IF (opacity IS NULL OR position(decode('00','hex') IN opacity)=0)
                    AND (stroke.kind<>3 OR (stroke.v>=0 AND stroke.v+(n-1)*stroke.dv<tex.h))
                    AND stroke.depth < ALL(zbuffer[stroke.y0:stroke.y1-1]) THEN
                    column_data:=overlay(column_data PLACING sample FROM stroke.y0+1 FOR n);
                    column_light:=overlay(column_light PLACING substring(shade_run[band+1] FOR n) FROM stroke.y0+1 FOR n);
                    zbuffer[stroke.y0:stroke.y1-1]:=array_fill(stroke.depth,ARRAY[n]);
                    CONTINUE;
                END IF;
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
