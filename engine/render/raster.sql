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
BEGIN
    IF n=1 THEN RETURN substring(colors FROM col+j+1 FOR 1); END IF;
    IF n<=h AND ((dv=1 AND phase=0) OR (least(phase,last_phase)>guard AND greatest(phase,last_phase)<1-guard)) THEN
        IF j+n<=h THEN RETURN substring(colors FROM col+j+1 FOR n); END IF;
        RETURN substring(colors FROM col+j+1 FOR h-j)||substring(colors FROM col+1 FOR n-(h-j));
    END IF;
    IF floor(v+(n-1)*dv)=row0 THEN RETURN decode(repeat(encode(substring(colors FROM col+j+1 FOR 1),'hex'),n),'hex'); END IF;
    result:=decode(repeat('00',n),'hex');
    IF (h&(h-1))=0 THEN
        FOR i IN 0..n-1 LOOP
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

CREATE TYPE doom.tile AS (w int,h int,pixels bytea,mask bytea);
CREATE FUNCTION doom.sprite_strokes(p bigint,g bigint,body doom.actors,fx float8,fy float8,far_z float8)
RETURNS SETOF doom.stroke LANGUAGE sql STABLE STRICT AS $$
    WITH projected AS (
        SELECT a.id,a.art,im.w,im.h,im.origin_x,im.origin_y,a.z,s.light,
            greatest(coalesce(m.floor_z,s.floor_z),a.z+im.origin_y-im.h) AS bottom,
            least(coalesce(m.ceiling_z,s.ceiling_z),a.z+im.origin_y) AS top,
            (a.pos[0]-body.pos[0])*fx+(a.pos[1]-body.pos[1])*fy AS depth,
            (a.pos[0]-body.pos[0])*fy-(a.pos[1]-body.pos[1])*fx AS rightward
        FROM doom.actors a JOIN doom.art im ON im.id=a.art JOIN doom.sectors s ON s.level=p AND s.id=a.sector
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
$$;

CREATE TYPE doom.plane_lut AS (depths float8[],bands bytea);
CREATE FUNCTION doom.frame(gid bigint,generation bigint,slot bigint DEFAULT 0)
RETURNS TABLE(epoch bigint,tic bigint,frame_slot bigint,width int,height int,pixels bytea,shades bytea)
LANGUAGE plpgsql STABLE STRICT SET jit=off AS $$
DECLARE
    p bigint;
    body doom.actors;
    fx float8;
    fy float8;
    sx float8;
    sy float8;
    eye float8;
    row_scale float8[];
    stroke doom.stroke;
    strokes doom.stroke[];
    world doom.stroke[];
    horizon float8;
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
    SELECT screen.row_scale INTO row_scale FROM doom.screen;
    fx:=cos(body.yaw); fy:=sin(body.yaw); eye:=body.z+41;
    SELECT least(32,length(lighting)/256)-1 INTO bands FROM doom.levels WHERE id=p;
    camera_x:=body.pos[0]; camera_y:=-body.pos[1];
    SELECT array_agg(s),CASE WHEN sum(y1-y0) FILTER(WHERE kind<3)=16000 THEN max(
        CASE WHEN kind=0 THEN greatest(row_scale[y0+1],row_scale[y1])*abs(eye-v) ELSE depth END
    ) ELSE 'Infinity'::float8 END
    INTO world,horizon FROM doom.world_strokes(p,gid,body,fx,fy)s;
    SELECT array_agg(s ORDER BY x,(kind>=3),CASE WHEN kind>=3 THEN -depth END,kind,art,y0) INTO strokes FROM (
        SELECT * FROM unnest(world) UNION ALL
        SELECT * FROM doom.sprite_strokes(p,gid,body,fx,fy,horizon)
    ) s;
    -- Each plane has a single depth and light per scanline, across its entire width.
    SELECT array_agg(key ORDER BY key),array_agg(ROW(ds,ramp)::doom.plane_lut ORDER BY key)
    INTO plane_keys,planes FROM (
        SELECT key,array_agg(projection.z ORDER BY y) AS ds,
            decode(string_agg(lpad(to_hex(least(bands,(255-light)/8+floor(projection.z/96)::int)),2,'0'),'' ORDER BY y),'hex') AS ramp
        FROM (SELECT DISTINCT v,light,(v::int*256+light) AS key FROM unnest(world) WHERE kind=0) surfaces,
        generate_series(0,99)y,LATERAL(SELECT abs(eye-v)*row_scale[y+1] AS z) projection GROUP BY key
    ) luts;
    -- Read and detoast only the textures actually present in this view.
    SELECT min(art) INTO first_art FROM unnest(strokes);
    SELECT array_agg(CASE WHEN a.id IS NOT NULL THEN ROW(a.w,a.h,substring(a.pixels FROM 1),
        substring(a.mask FROM 1))::doom.tile END ORDER BY id_range) INTO bank
    FROM generate_series(first_art,(SELECT max(art) FROM unnest(strokes)))id_range
    LEFT JOIN (SELECT DISTINCT art FROM unnest(strokes)) used ON used.art=id_range
    LEFT JOIN doom.art a ON a.id=used.art;
    SELECT array_agg(decode(repeat(lpad(to_hex(i),2,'0'),100),'hex') ORDER BY i) INTO shade_run FROM generate_series(0,bands)i;
    SELECT array_agg(x) INTO overlay_columns FROM (SELECT DISTINCT x FROM unnest(strokes) WHERE kind>=3) overlay_cols;
    FOREACH stroke IN ARRAY coalesce(strokes,'{}') LOOP
        IF stroke.x<>this_x THEN
            IF this_x>=0 THEN colors[this_x]:=column_data; lights[this_x]:=column_light; END IF;
            this_x:=stroke.x; column_data:=empty_column; column_light:=empty_column;
            has_overlay:=coalesce(this_x=ANY(overlay_columns),false);
            IF has_overlay THEN zbuffer:=array_fill('Infinity'::float8,ARRAY[100],ARRAY[0]); END IF;
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
                FOR y IN stroke.y0..stroke.y1-1 LOOP
                    z:=plane.depths[y+1];
                    idx:=(floor(camera_x+sx*z)::bigint & 63)+64*(floor(camera_y-sy*z)::bigint & 63);
                    column_data:=set_byte(column_data,y,get_byte(tex.pixels,idx));
                END LOOP;
            END IF;
        ELSE
            IF stroke.kind>=3 AND NOT (stroke.depth < ANY(zbuffer[stroke.y0:stroke.y1-1])) THEN CONTINUE; END IF;
            band:=CASE WHEN stroke.kind=2 THEN 0 ELSE least(bands,level_light+floor(stroke.depth/96)::int) END;
            sample:=coalesce(doom.column_samples(tex.pixels,tex.w,tex.h,stroke.u,stroke.v,stroke.dv,n),substring(empty_column FOR n));
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
    IF this_x>=0 THEN colors[this_x]:=column_data; lights[this_x]:=column_light; END IF;
    SELECT string_agg(c,''::bytea ORDER BY i) INTO pixels FROM unnest(colors) WITH ORDINALITY b(c,i);
    SELECT string_agg(c,''::bytea ORDER BY i) INTO shades FROM unnest(lights) WITH ORDINALITY b(c,i);
    width:=160; height:=100; frame_slot:=slot; RETURN NEXT;
END;
$$;

CREATE FUNCTION doom.frame_palette(gid bigint) RETURNS bytea LANGUAGE sql STABLE STRICT AS $$
    SELECT string_agg(substring(l.palette FROM 1+3*get_byte(l.lighting,i) FOR 3),''::bytea ORDER BY i)
    FROM doom.games g JOIN doom.levels l ON l.id=g.level,
        LATERAL generate_series(0,least(length(l.lighting),32*256)-1)i WHERE g.id=gid;
$$;
COMMENT ON FUNCTION doom.frame(bigint,bigint,bigint) IS
'Column-major 8-bit pixels and shades. At (x,y), i=x*height+y. RGB starts at 3*(256*shades[i]+pixels[i]) in frame_palette(game).';
