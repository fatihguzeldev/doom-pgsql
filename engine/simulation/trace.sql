CREATE FUNCTION doom.trace(p bigint,g bigint,origin point,delta point,start_sector int,eye float8)
RETURNS TABLE(line int,sector int,other int,t float8,blocked boolean)
LANGUAGE plpgsql STABLE STRICT AS $$
DECLARE
    hit record;
    direction int := start_sector;
BEGIN
    FOR hit IN
        WITH contacts AS (
            SELECT l.id,l.front,l.back,
                (v[0]*edge[1]-v[1]*edge[0])/den AS k,(v[0]*delta[1]-v[1]*delta[0])/den AS u
            FROM doom.lines l,LATERAL(SELECT l.b-l.a AS edge,l.a-origin AS v) ab,
                LATERAL(SELECT nullif(delta[0]*edge[1]-delta[1]*edge[0],0) AS den)d
            WHERE l.level=p AND box(l.a,l.b) && box(origin,origin+delta)
        )
        SELECT c.id,c.k,f.sector AS r,b.sector AS s
        FROM contacts c JOIN doom.sides f ON f.level=p AND f.id=c.front
        LEFT JOIN doom.sides b ON b.level=p AND b.id=c.back
        WHERE c.k BETWEEN 0 AND 1 AND c.u BETWEEN 0 AND 1
        ORDER BY c.k,(c.back IS NULL) DESC,c.id
    LOOP
        CONTINUE WHEN direction<>hit.r AND direction IS DISTINCT FROM hit.s;
        sector:=direction; line:=hit.id; t:=hit.k;
        other:=CASE WHEN direction=hit.r THEN hit.s ELSE hit.r END;
        blocked:=other IS NULL;
        IF NOT blocked THEN
            SELECT eye<max(coalesce(m.floor_z,s.floor_z)) OR eye>=min(coalesce(m.ceiling_z,s.ceiling_z))
            INTO blocked FROM doom.sectors s LEFT JOIN doom.movers m ON m.game=g AND m.sector=s.id
            WHERE s.level=p AND s.id IN (direction,other);
        END IF;
        RETURN NEXT;
        EXIT WHEN blocked;
        direction:=other;
    END LOOP;
END;
$$;

CREATE TYPE doom.location AS (pos point,sector int,z float8);
-- The diagonal move and both slide attempts share a bounding box and portal heights.
CREATE FUNCTION doom.try_move(p bigint,body doom.actors,next_pos point,slide boolean) RETURNS doom.location
LANGUAGE plpgsql STABLE STRICT AS $$
DECLARE
    tiles doom.blockmap[];
    tile doom.blockmap;
    obstacle doom.boundary;
    targets point[]:=ARRAY[next_pos];
    target point;
    path lseg;
    portal_ids int[]:='{}';
    passable boolean[]:='{}';
    portal int;
    bottom int;
    top_z int;
    blocked boolean;
    crossed boolean;
    dest int;
    floor_at int;
BEGIN
    SELECT array_agg(b) INTO tiles FROM doom.blockmap b WHERE b.level=p
        AND b.x BETWEEN ceil((least(body.pos[0],next_pos[0])-body.radius)/128)::int-1
            AND floor((greatest(body.pos[0],next_pos[0])+body.radius)/128)::int
        AND b.y BETWEEN ceil((least(body.pos[1],next_pos[1])-body.radius)/128)::int-1
            AND floor((greatest(body.pos[1],next_pos[1])+body.radius)/128)::int;
    IF slide AND body.pos[0]<>next_pos[0] AND body.pos[1]<>next_pos[1] THEN
        targets:=targets||ARRAY[point(next_pos[0],body.pos[1]),point(body.pos[0],next_pos[1])];
    END IF;
    <<attempt>>
    FOREACH target IN ARRAY targets LOOP
        path:=lseg(body.pos,target); crossed:=false;
        FOREACH tile IN ARRAY coalesce(tiles,'{}') LOOP
            FOREACH obstacle IN ARRAY tile.walls LOOP
                CONTINUE WHEN path <-> obstacle.segment > body.radius;
                blocked:=obstacle.back IS NULL OR (obstacle.flags & 1)<>0 OR (body.role='monster' AND (obstacle.flags&2)<>0);
                IF NOT blocked THEN
                    portal:=array_position(portal_ids,obstacle.id);
                    IF portal IS NULL THEN
                        SELECT max(coalesce(m.floor_z,s.floor_z)),min(coalesce(m.ceiling_z,s.ceiling_z)) INTO bottom,top_z
                        FROM doom.sectors s LEFT JOIN doom.movers m ON m.game=body.game AND m.sector=s.id
                        WHERE s.level=p AND s.id IN (obstacle.front,obstacle.back);
                        blocked:=bottom>body.z+24 OR top_z-greatest(body.z,bottom)<body.height;
                        portal_ids:=array_append(portal_ids,obstacle.id);
                        passable:=array_append(passable,NOT blocked);
                    ELSE
                        blocked:=NOT passable[portal];
                    END IF;
                END IF;
                IF blocked THEN
                    CONTINUE attempt WHEN path ?# obstacle.segment OR (target <-> obstacle.segment)<=(body.pos <-> obstacle.segment);
                ELSE
                    crossed:=crossed OR path ?# obstacle.segment;
                END IF;
            END LOOP;
        END LOOP;
        IF EXISTS (SELECT FROM doom.actors a WHERE a.game=body.game AND a.id<>body.id AND a.health>0
            AND a.role IN ('player','monster','barrel')
            AND a.cell_x BETWEEN floor((target[0]-body.radius-32)/128)::int AND floor((target[0]+body.radius+32)/128)::int
            AND a.cell_y BETWEEN floor((target[1]-body.radius-32)/128)::int AND floor((target[1]+body.radius+32)/128)::int
            AND body.z<a.z+a.height AND body.z+body.height>a.z AND (a.pos<->target)<a.radius+body.radius
            AND (a.pos<->target)<=(a.pos<->body.pos)) THEN CONTINUE; END IF;
        dest:=body.sector;
        IF crossed OR dest<0 THEN
            dest:=doom.sector_at(p,target);
            CONTINUE WHEN dest IS NULL;
        END IF;
        SELECT coalesce(m.floor_z,s.floor_z) INTO floor_at FROM doom.sectors s
        LEFT JOIN doom.movers m ON m.game=body.game AND m.sector=s.id WHERE s.level=p AND s.id=dest;
        RETURN (target,dest,floor_at)::doom.location;
    END LOOP;
    RETURN NULL;
END;
$$;

CREATE FUNCTION doom.try_move(p bigint,body doom.actors,next_pos point) RETURNS doom.location
LANGUAGE sql STABLE STRICT RETURN doom.try_move(p,body,next_pos,false);
