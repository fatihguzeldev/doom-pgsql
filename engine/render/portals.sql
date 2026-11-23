CREATE TYPE doom.projection AS (
    wall doom.edge, lo int, hi int, z0 float8, r0 float8, dz float8, dr float8, k float8,
    inv0 float8, inv_step float8
);
CREATE TYPE doom.aperture AS (sector int, lo int, hi int, entry int, inv0 float8, inv_step float8);

-- Between projected endpoints, the nearest edge changes only where two inverse-depth lines cross.
CREATE FUNCTION doom.visible(mesh doom.edge[],win doom.aperture,eye point,fx float8,fy float8)
RETURNS SETOF doom.projection LANGUAGE plpgsql IMMUTABLE STRICT ROWS 4 AS $$
DECLARE
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
        line.lo:=greatest(win.lo,least(160,ceil(79.5+80*left_r)))::int;
        line.hi:=least(win.hi,greatest(-1,ceil(79.5+80*right_r)-1))::int;
        CONTINUE WHEN line.lo>line.hi;
        line.inv0:=(line.dr+79.5/80*line.dz)/line.k;
        line.inv_step:=-line.dz/(80*line.k);
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

CREATE TYPE doom.room AS (z_floor float8,z_ceil float8,light int,floor_id int,ceil_id int,sky boolean);
CREATE TABLE doom.room_catalog (
    level bigint PRIMARY KEY REFERENCES doom.levels ON DELETE CASCADE, rooms doom.room[] NOT NULL
);
CREATE FUNCTION doom.publish_rooms() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO doom.room_catalog
    SELECT NEW.id,coalesce(array_agg(CASE WHEN s.id IS NOT NULL THEN ROW(s.floor_z,s.ceiling_z,s.light,
        b.floor_id,b.ceiling_id,b.sky)::doom.room END ORDER BY i),'{}'::doom.room[])
    FROM generate_series(0,(SELECT max(id) FROM doom.sectors WHERE level=NEW.id)) i
    LEFT JOIN doom.sectors s ON s.level=NEW.id AND s.id=i
    LEFT JOIN doom.mesh b ON b.level=NEW.id AND b.sector=i
    ON CONFLICT(level) DO UPDATE SET rooms=excluded.rooms;
    RETURN NULL;
END;
$$;
CREATE TRIGGER publish_rooms AFTER UPDATE OF revision ON doom.levels FOR EACH ROW EXECUTE FUNCTION doom.publish_rooms();
CREATE TABLE doom.screen (
    sky_angles float8[] NOT NULL, row_scale float8[] NOT NULL, shade_runs bytea[] NOT NULL, singleton boolean PRIMARY KEY CHECK(singleton)
);
INSERT INTO doom.screen SELECT ARRAY(SELECT atan((x-79.5)/80) FROM generate_series(0,159)x),
    ARRAY(SELECT 80/abs(y-49.5::float8) FROM generate_series(0,99)y),
    ARRAY(SELECT decode(repeat(lpad(to_hex(i),2,'0'),100),'hex') FROM generate_series(0,31)i),true;

CREATE TYPE doom.stroke AS (
    x int,y0 int,y1 int,kind int,art int,u float8,v float8,dv float8,depth float8,light int
);
-- Sprites are drawn separately. A moving door can change the background even when the camera is still.
CREATE TABLE doom.view_cache (
    game bigint PRIMARY KEY REFERENCES doom.games ON DELETE CASCADE, revision bigint NOT NULL,
    x float8 NOT NULL,y float8 NOT NULL,z float8 NOT NULL,yaw float8 NOT NULL,sector int NOT NULL,
    openings text NOT NULL, background bytea, illumination bytea, depths float8[], far_z float8
);
CREATE TABLE doom.view_edges (
    game bigint REFERENCES doom.view_cache ON DELETE CASCADE,bucket int,edges doom.edge[] NOT NULL,
    PRIMARY KEY(game,bucket)
);
CREATE FUNCTION doom.opening_key(g bigint) RETURNS text LANGUAGE sql STABLE STRICT AS $$
    SELECT md5(concat_ws('/',
        (SELECT md5(string_agg(record_send(ROW(sector,floor_z,ceiling_z)),''::bytea ORDER BY sector)) FROM doom.movers WHERE game=g),
        (SELECT md5(string_agg(record_send(ROW(sector,light,floor_id)),''::bytea ORDER BY sector)) FROM doom.room_changes WHERE game=g)));
$$;
CREATE TYPE doom.wall_run AS (projection doom.projection,anchor float8,light int);
CREATE TYPE doom.world_view AS (strokes doom.stroke[],runs doom.wall_run[]);

-- Match the order of floating-point operations in project_world for clipped columns.
CREATE FUNCTION doom.wall_rays(runs doom.wall_run[]) RETURNS SETOF doom.stroke
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
    SELECT x,0,100,1,e.mid_id,
        e.u+e.len*greatest(0,least(1,((x-79.5::float8)/80*p.z0-p.r0)/(d.inv*p.k))),
        r.anchor-49.5*(z.depth/80),z.depth/80,z.depth,r.light
    FROM unnest(runs) r CROSS JOIN LATERAL (SELECT (r.projection).*) p
    CROSS JOIN LATERAL (SELECT (p.wall).*) e CROSS JOIN LATERAL generate_series(p.lo,p.hi)x
    CROSS JOIN LATERAL (SELECT p.inv0+x*p.inv_step AS inv)d
    CROSS JOIN LATERAL (SELECT 1/d.inv AS depth)z;
$$;

-- kind 0 plane (v is world height), 1 solid column, 2 sky, 3 masked column.
CREATE FUNCTION doom.project_world(p bigint,g bigint,body doom.actors,fx float8,fy float8)
RETURNS doom.world_view LANGUAGE plpgsql STABLE STRICT AS $$
DECLARE
    view_data doom.world_view;
    fragments doom.stroke[];
    far_scale float8;
    queue doom.aperture[]:=ARRAY[ROW(body.sector,0,159,-1,0,0)::doom.aperture];
    tail int:=1;
    win doom.aperture;
    wall doom.projection;
    e doom.edge;
    edges doom.edge[];
    rooms doom.room[];
    moving doom.movers;
    changed doom.room_changes;
    sky_angles float8[];
    front doom.room;
    back doom.room;
    top_clip int[]:=array_fill(0,ARRAY[160],ARRAY[0]);
    bottom_clip int[]:=array_fill(100,ARRAY[160],ARRAY[0]);
    eye float8:=body.z+41;
    inverse float8; depth float8; scale float8; dv float8; u float8;
    top_y int; bottom_y int; top_open int; bottom_open int;
    clear_portal boolean;
    solid_anchor float8; upper_anchor float8; lower_anchor float8; middle_anchor float8;
    open_from int; low_z float8; high_z float8; origin_z float8;
    y0 int; y1 int;
BEGIN
    SELECT c.rooms INTO STRICT rooms FROM doom.room_catalog c WHERE c.level=p;
    SELECT s.sky_angles INTO sky_angles FROM doom.screen s;
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
        FOR wall IN SELECT * FROM doom.visible(edges,win,body.pos,fx,fy) LOOP
            e:=wall.wall; back:=rooms[1+e.dest]; open_from:=NULL;
            -- A full-screen portal with no earlier strokes still has the root clip bounds.
            IF e.dest IS NULL AND e.mid_id IS NOT NULL AND (win.entry=-1 OR
                (win.lo=0 AND win.hi=159 AND fragments IS NULL AND view_data.runs IS NULL)) THEN
                far_scale:=80*least(wall.inv0+wall.lo*wall.inv_step,wall.inv0+wall.hi*wall.inv_step);
                IF far_scale>0 AND 49.5+(eye-front.z_ceil)*far_scale<=0 AND
                    49.5+(eye-front.z_floor)*far_scale>99 THEN
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
            -- Sibling apertures partition x. Only open columns enter a child,
            -- so no pending window can revisit a column closed by this wall.
            FOR x IN wall.lo..wall.hi LOOP
                y0:=top_clip[x]; y1:=bottom_clip[x];
                inverse:=wall.inv0+x*wall.inv_step; depth:=1/inverse; scale:=80*inverse; dv:=depth/80;
                IF NOT clear_portal THEN
                    u:=e.u+e.len*greatest(0,least(1,((x-79.5::float8)/80*wall.z0-wall.r0)/(inverse*wall.k)));
                END IF;
                top_y:=greatest(y0,least(y1,ceil(49.5+(eye-front.z_ceil)*scale)))::int;
                bottom_y:=greatest(top_y,least(y1,ceil(49.5+(eye-front.z_floor)*scale)))::int;
                IF y0<top_y THEN
                    IF front.sky THEN fragments:=array_append(fragments,(x,y0,top_y,2,front.ceil_id,
                        (body.yaw-sky_angles[1+x])*512/pi(),y0,1,depth,255)::doom.stroke);
                    ELSE fragments:=array_append(fragments,(x,y0,top_y,0,front.ceil_id,0,front.z_ceil,0,depth,front.light)::doom.stroke); END IF;
                END IF;
                IF bottom_y<y1 THEN fragments:=array_append(fragments,(x,bottom_y,y1,0,front.floor_id,0,front.z_floor,0,depth,front.light)::doom.stroke); END IF;
                IF e.dest IS NULL THEN
                    IF top_y<bottom_y THEN
                        fragments:=array_append(fragments,(x,top_y,bottom_y,1,e.mid_id,u,solid_anchor+(top_y-49.5)*dv,dv,depth,front.light)::doom.stroke);
                    END IF;
                ELSIF clear_portal THEN
                    top_clip[x]:=top_y; bottom_clip[x]:=bottom_y;
                ELSE
                    bottom_open:=greatest(top_y,least(bottom_y,ceil(49.5+(eye-low_z)*scale)))::int;
                    top_open:=CASE WHEN front.sky AND back.sky AND low_z<high_z THEN top_y ELSE
                        greatest(top_y,least(bottom_open,ceil(49.5+(eye-high_z)*scale)))::int END;
                    IF top_y<top_open THEN
                        fragments:=array_append(fragments,(x,top_y,top_open,1,e.upper_id,u,upper_anchor+(top_y-49.5)*dv,dv,depth,front.light)::doom.stroke);
                    END IF;
                    IF bottom_open<bottom_y THEN
                        fragments:=array_append(fragments,(x,bottom_open,bottom_y,1,e.lower_id,u,lower_anchor+(bottom_open-49.5)*dv,dv,depth,front.light)::doom.stroke);
                    END IF;
                    IF e.mid_id IS NOT NULL AND top_open<bottom_open THEN
                        fragments:=array_append(fragments,(x,top_open,bottom_open,3,e.mid_id,u,middle_anchor+(top_open-49.5)*dv,dv,depth,front.light)::doom.stroke);
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

CREATE FUNCTION doom.world_strokes(p bigint,g bigint,body doom.actors,fx float8,fy float8)
RETURNS SETOF doom.stroke LANGUAGE sql STABLE STRICT AS $$
    WITH world AS MATERIALIZED (SELECT doom.project_world(p,g,body,fx,fy) AS v)
    SELECT s.* FROM world,unnest((v).strokes)s
    UNION ALL SELECT r.* FROM world,doom.wall_rays((v).runs)r;
$$;
