-- between projected endpoints, the nearest edge changes only where two inverse-depth lines cross.
CREATE OR REPLACE FUNCTION doom.visible(mesh doom.edge[],win doom.aperture,eye point,fx float8,fy float8,screen_width int)
RETURNS SETOF doom.projection LANGUAGE plpgsql IMMUTABLE STRICT ROWS 4 AS $$
DECLARE
    focal float8:=screen_width::float8/2;
    center_x float8:=focal-0.5;
    e doom.edge;
    line doom.projection;
    candidates doom.projection[] := '{}';
    nearest doom.projection;
    d point;
    z1 float8; r1 float8; left_r float8; right_r float8;
    at_x int; until_x int; low_x int; high_x int; mid int;
    eligible_left boolean; eligible_right boolean; eligible boolean;
    inv float8; best float8; best_last float8;
BEGIN
    FOREACH e IN ARRAY mesh LOOP
        CONTINUE WHEN e.line=win.entry OR (e.dest=win.sector AND e.mid_id IS NULL);
        d:=e.a-eye;
        line.z0:=d[0]*fx+d[1]*fy; line.r0:=d[0]*fy-d[1]*fx;
        line.dz:=e.dx*fx+e.dy*fy; line.dr:=e.dx*fy-e.dy*fx;
        z1:=line.z0+line.dz; r1:=line.r0+line.dr;
        CONTINUE WHEN greatest(line.z0,z1)<0.001 OR greatest(line.z0+line.r0,z1+r1)<0
            OR greatest(line.z0-line.r0,z1-r1)<0;
        line.k:=line.z0*line.dr-line.r0*line.dz;
        CONTINUE WHEN line.k<=0;
        left_r:=CASE WHEN line.z0>=0.001 THEN line.r0/line.z0 ELSE (line.r0+(0.001-line.z0)*line.dr/line.dz)/0.001 END;
        right_r:=CASE WHEN z1>=0.001 THEN r1/z1 ELSE (r1+(0.001-z1)*line.dr/line.dz)/0.001 END;
        line.lo:=greatest(win.lo,least(screen_width,ceil(center_x+focal*left_r)))::int;
        line.hi:=least(win.hi,greatest(-1,ceil(center_x+focal*right_r)-1))::int;
        CONTINUE WHEN line.lo>line.hi;
        line.inv0:=(line.dr+center_x/focal*line.dz)/line.k;
        line.inv_step:=-line.dz/(focal*line.k);
        IF win.entry>=0 THEN
            eligible_left:=(line.inv0+line.lo*line.inv_step,-e.line)<(win.inv0+line.lo*win.inv_step,-win.entry);
            eligible_right:=(line.inv0+line.hi*line.inv_step,-e.line)<(win.inv0+line.hi*win.inv_step,-win.entry);
            CONTINUE WHEN NOT eligible_left AND NOT eligible_right;
            IF eligible_left<>eligible_right THEN
                low_x:=line.lo; high_x:=line.hi;
                WHILE high_x-low_x>1 LOOP
                    mid:=(low_x+high_x)/2;
                    eligible:=(line.inv0+mid*line.inv_step,-e.line)<(win.inv0+mid*win.inv_step,-win.entry);
                    IF eligible=eligible_left THEN low_x:=mid; ELSE high_x:=mid; END IF;
                END LOOP;
                IF eligible_left THEN line.hi:=low_x; ELSE line.lo:=high_x; END IF;
            END IF;
        END IF;
        line.wall:=e;
        candidates:=array_append(candidates,line);
    END LOOP;
    at_x:=win.lo;
    WHILE at_x<=win.hi LOOP
        until_x:=win.hi;
        nearest:=NULL; best:=0;
        FOREACH line IN ARRAY candidates LOOP
            CONTINUE WHEN line.hi<at_x;
            IF line.lo>at_x THEN until_x:=least(until_x,line.lo-1); CONTINUE; END IF;
            until_x:=least(until_x,line.hi);
            inv:=line.inv0+at_x*line.inv_step;
            IF inv>best OR (inv=best AND (line.wall).line<(nearest.wall).line) THEN nearest:=line; best:=inv; END IF;
        END LOOP;
        IF nearest.lo IS NOT NULL THEN
            best_last:=nearest.inv0+until_x*nearest.inv_step;
            FOREACH line IN ARRAY candidates LOOP
                CONTINUE WHEN line.lo>at_x OR line.hi<at_x OR (line.wall).line=(nearest.wall).line;
                IF (line.inv0+until_x*line.inv_step,-(line.wall).line)>(best_last,-(nearest.wall).line) THEN
                    low_x:=at_x; high_x:=until_x;
                    WHILE high_x-low_x>1 LOOP
                        mid:=(low_x+high_x)/2;
                        IF (line.inv0+mid*line.inv_step,-(line.wall).line)>
                           (nearest.inv0+mid*nearest.inv_step,-(nearest.wall).line) THEN high_x:=mid; ELSE low_x:=mid; END IF;
                    END LOOP;
                    until_x:=low_x; best_last:=nearest.inv0+until_x*nearest.inv_step;
                END IF;
            END LOOP;
            nearest.lo:=at_x; nearest.hi:=until_x;
            RETURN NEXT nearest;
        END IF;
        at_x:=until_x+1;
    END LOOP;
END;
$$;

-- match the order of floating-point operations in project_world for clipped columns.
CREATE OR REPLACE FUNCTION doom.wall_rays(runs doom.wall_run[],screen_width int,screen_height int) RETURNS SETOF doom.stroke
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
    SELECT x,0,screen_height,1,e.mid_id,
        e.u+e.len*greatest(0,least(1,((x-center_x)/focal*p.z0-p.r0)/(d.inv*p.k))),
        r.anchor-center_y*(z.depth/focal),z.depth/focal,z.depth,r.light
    FROM unnest(runs) r
    CROSS JOIN LATERAL (SELECT screen_width::float8/2 AS focal, (screen_width-1)::float8/2 AS center_x,
                               (screen_height-1)::float8/2 AS center_y) screen
    CROSS JOIN LATERAL (SELECT (r.projection).*) p
    CROSS JOIN LATERAL (SELECT (p.wall).*) e CROSS JOIN LATERAL generate_series(p.lo,p.hi)x
    CROSS JOIN LATERAL (SELECT p.inv0+x*p.inv_step AS inv)d
    CROSS JOIN LATERAL (SELECT 1/d.inv AS depth)z;
$$;

CREATE OR REPLACE FUNCTION doom.project_world(p bigint,g bigint,body doom.actors,fx float8,fy float8,cam doom.viewports)
RETURNS doom.world_view LANGUAGE plpgsql STABLE STRICT AS $$
DECLARE
    view_data doom.world_view;
    fragments doom.stroke[];
    far_scale float8;
    queue doom.aperture[]:=ARRAY[ROW(body.sector,0,cam.w-1,-1,0,0)::doom.aperture];
    tail int:=1;
    win doom.aperture;
    wall doom.projection;
    e doom.edge;
    edges doom.edge[];
    rooms doom.room[];
    moving doom.movers;
    changed doom.room_changes;
    front doom.room;
    back doom.room;
    top_clip int[]:=array_fill(0,ARRAY[cam.w],ARRAY[0]);
    bottom_clip int[]:=array_fill(cam.h,ARRAY[cam.w],ARRAY[0]);
    eye float8:=body.z+41;
    inverse float8; depth float8; scale float8; dv float8; u float8;
    top_y int; bottom_y int; top_open int; bottom_open int;
    clear_portal boolean;
    solid_anchor float8; upper_anchor float8; lower_anchor float8; middle_anchor float8;
    open_from int; low_z float8; high_z float8; origin_z float8;
    y0 int; y1 int;
BEGIN
    SELECT c.rooms INTO STRICT rooms FROM doom.room_catalog c WHERE c.level=p;
    FOR moving IN SELECT * FROM doom.movers WHERE game=g LOOP
        front:=rooms[1+moving.sector]; front.z_floor:=moving.floor_z; front.z_ceil:=moving.ceiling_z;
        rooms[1+moving.sector]:=front;
    END LOOP;
    FOR changed IN SELECT * FROM doom.room_changes WHERE game=g LOOP
        front:=rooms[1+changed.sector]; front.light:=coalesce(changed.light,front.light);
        front.floor_id:=coalesce(changed.floor_id,front.floor_id); rooms[1+changed.sector]:=front;
    END LOOP;
    WHILE tail>0 LOOP
        win:=queue[tail]; tail:=tail-1;
        edges:=NULL;
        IF win.entry=-1 THEN
            SELECT b.edges INTO edges FROM doom.view_cache v JOIN doom.view_edges b USING(game)
            WHERE v.game=g AND v.x=body.pos[0] AND v.y=body.pos[1] AND v.sector=win.sector
                AND v.revision=(SELECT revision FROM doom.levels WHERE id=p)
                AND b.bucket=(floor(body.yaw*8/pi()+0.5)::int & 15);
        END IF;
        IF edges IS NULL THEN SELECT m.edges INTO edges FROM doom.mesh m WHERE m.level=p AND m.sector=win.sector; END IF;
        front:=rooms[1+win.sector];
        FOR wall IN SELECT * FROM doom.visible(edges,win,body.pos,fx,fy,cam.w) LOOP
            e:=wall.wall; back:=rooms[1+e.dest]; open_from:=NULL;
            -- a full-screen portal with no earlier strokes still has the root clip bounds.
            IF e.dest IS NULL AND e.mid_id IS NOT NULL AND (win.entry=-1 OR
                (win.lo=0 AND win.hi=cam.w-1 AND fragments IS NULL AND view_data.runs IS NULL)) THEN
                far_scale:=cam.focal*least(wall.inv0+wall.lo*wall.inv_step,wall.inv0+wall.hi*wall.inv_step);
                IF far_scale>0 AND cam.cy+(eye-front.z_ceil)*far_scale<=0 AND
                    cam.cy+(eye-front.z_floor)*far_scale>cam.h-1 THEN
                    origin_z:=CASE WHEN (e.flags&16)=0 THEN front.z_ceil ELSE front.z_floor+coalesce(e.mid_h,0) END;
                    view_data.runs:=array_append(view_data.runs,(wall,e.v+origin_z-eye,front.light)::doom.wall_run);
                    CONTINUE;
                END IF;
            END IF;
            low_z:=greatest(front.z_floor,back.z_floor); high_z:=least(front.z_ceil,back.z_ceil);
            clear_portal:=e.dest IS NOT NULL AND e.mid_id IS NULL AND low_z=front.z_floor AND
                (high_z=front.z_ceil OR (front.sky AND back.sky AND low_z<high_z));
            solid_anchor:=e.v+CASE WHEN (e.flags&16)=0 THEN front.z_ceil ELSE front.z_floor+coalesce(e.mid_h,0) END-eye;
            upper_anchor:=e.v+CASE WHEN (e.flags&8)=0 THEN back.z_ceil+coalesce(e.upper_h,0) ELSE front.z_ceil END-eye;
            lower_anchor:=e.v+CASE WHEN (e.flags&16)<>0 THEN front.z_ceil ELSE back.z_floor END-eye;
            middle_anchor:=e.v+CASE WHEN (e.flags&16)=0 THEN high_z ELSE low_z+e.mid_h END-eye;
            -- sibling apertures partition x. only open columns enter a child,
            -- so no pending window can revisit a column closed by this wall.
            FOR x IN wall.lo..wall.hi LOOP
                y0:=top_clip[x]; y1:=bottom_clip[x];
                inverse:=wall.inv0+x*wall.inv_step; depth:=1/inverse; scale:=cam.focal*inverse; dv:=depth/cam.focal;
                IF NOT clear_portal THEN
                    u:=e.u+e.len*greatest(0,least(1,((x-cam.cx)/cam.focal*wall.z0-wall.r0)/(inverse*wall.k)));
                END IF;
                top_y:=greatest(y0,least(y1,ceil(cam.cy+(eye-front.z_ceil)*scale)))::int;
                bottom_y:=greatest(top_y,least(y1,ceil(cam.cy+(eye-front.z_floor)*scale)))::int;
                IF y0<top_y THEN
                    IF front.sky THEN fragments:=array_append(fragments,(x,y0,top_y,2,front.ceil_id,
                        (body.yaw-cam.sky_angles[1+x])*512/pi(),(y0+0.5)*cam.sky_step-0.5,cam.sky_step,depth,255)::doom.stroke);
                    ELSE fragments:=array_append(fragments,(x,y0,top_y,0,front.ceil_id,0,front.z_ceil,0,depth,front.light)::doom.stroke); END IF;
                END IF;
                IF bottom_y<y1 THEN fragments:=array_append(fragments,(x,bottom_y,y1,0,front.floor_id,0,front.z_floor,0,depth,front.light)::doom.stroke); END IF;
                IF e.dest IS NULL THEN
                    IF top_y<bottom_y THEN
                        fragments:=array_append(fragments,(x,top_y,bottom_y,1,e.mid_id,u,solid_anchor+(top_y-cam.cy)*dv,dv,depth,front.light)::doom.stroke);
                    END IF;
                ELSIF clear_portal THEN
                    top_clip[x]:=top_y; bottom_clip[x]:=bottom_y;
                ELSE
                    bottom_open:=greatest(top_y,least(bottom_y,ceil(cam.cy+(eye-low_z)*scale)))::int;
                    top_open:=CASE WHEN front.sky AND back.sky AND low_z<high_z THEN top_y ELSE
                        greatest(top_y,least(bottom_open,ceil(cam.cy+(eye-high_z)*scale)))::int END;
                    IF top_y<top_open THEN
                        fragments:=array_append(fragments,(x,top_y,top_open,1,e.upper_id,u,upper_anchor+(top_y-cam.cy)*dv,dv,depth,front.light)::doom.stroke);
                    END IF;
                    IF bottom_open<bottom_y THEN
                        fragments:=array_append(fragments,(x,bottom_open,bottom_y,1,e.lower_id,u,lower_anchor+(bottom_open-cam.cy)*dv,dv,depth,front.light)::doom.stroke);
                    END IF;
                    IF e.mid_id IS NOT NULL AND top_open<bottom_open THEN
                        fragments:=array_append(fragments,(x,top_open,bottom_open,3,e.mid_id,u,middle_anchor+(top_open-cam.cy)*dv,dv,depth,front.light)::doom.stroke);
                    END IF;
                    top_clip[x]:=top_open; bottom_clip[x]:=bottom_open;
                END IF;
                IF e.dest IS NOT NULL AND top_clip[x]<bottom_clip[x] THEN open_from:=coalesce(open_from,x); END IF;
                IF open_from IS NOT NULL AND (x=wall.hi OR top_clip[x]>=bottom_clip[x]) THEN
                    tail:=tail+1;
                    queue[tail]:=(e.dest,open_from,CASE WHEN top_clip[x]<bottom_clip[x] THEN x ELSE x-1 END,
                        e.line,wall.inv0,wall.inv_step)::doom.aperture;
                    open_from:=NULL;
                END IF;
            END LOOP;
        END LOOP;
    END LOOP;
    view_data.strokes:=fragments;
    RETURN view_data;
END;
$$;

CREATE OR REPLACE FUNCTION doom.visible(mesh doom.edge[],win doom.aperture,eye point,fx float8,fy float8)
RETURNS SETOF doom.projection LANGUAGE sql IMMUTABLE STRICT ROWS 4 AS $$
    SELECT * FROM doom.visible(mesh,win,eye,fx,fy,160);
$$;

CREATE OR REPLACE FUNCTION doom.wall_rays(runs doom.wall_run[])
RETURNS SETOF doom.stroke LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
    SELECT * FROM doom.wall_rays(runs,160,100);
$$;

CREATE OR REPLACE FUNCTION doom.project_world(p bigint,g bigint,body doom.actors,fx float8,fy float8)
RETURNS doom.world_view LANGUAGE sql STABLE STRICT AS $$
    SELECT f.* FROM doom.viewports cam CROSS JOIN LATERAL doom.project_world(p,g,body,fx,fy,cam) f WHERE cam.w=160;
$$;

CREATE OR REPLACE FUNCTION doom.world_strokes(p bigint,g bigint,body doom.actors,fx float8,fy float8)
RETURNS SETOF doom.stroke LANGUAGE sql STABLE STRICT AS $$
    WITH world AS MATERIALIZED (SELECT doom.project_world(p,g,body,fx,fy) AS v)
    SELECT s.* FROM world,unnest((v).strokes)s
    UNION ALL SELECT r.* FROM world,doom.wall_rays((v).runs)r;
$$;
