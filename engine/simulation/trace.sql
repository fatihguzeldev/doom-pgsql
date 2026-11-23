CREATE FUNCTION doom.trace(p bigint,g bigint,origin point,delta point,start_sector int,eye float8)
RETURNS TABLE(line int,sector int,other int,t float8,blocked boolean)
LANGUAGE plpgsql STABLE STRICT AS $$
DECLARE
    hit record;
    direction int := start_sector;
BEGIN
    FOR hit IN
        WITH boundaries AS MATERIALIZED (
            SELECT DISTINCT ON (w.id) w.* FROM doom.cells(origin,origin+delta)c
            JOIN doom.blockmap b ON b.level=p AND b.x=c.x AND b.y=c.y CROSS JOIN LATERAL unnest(b.walls)w
            ORDER BY w.id
        ), contacts AS (
            SELECT w.id,w.front AS r,w.back AS s,
                (v[0]*edge[1]-v[1]*edge[0])/den AS k,(v[0]*delta[1]-v[1]*delta[0])/den AS u
            FROM boundaries w,LATERAL(SELECT w.segment[1]-w.segment[0] AS edge,w.segment[0]-origin AS v) ab,
            LATERAL (SELECT nullif(delta[0]*edge[1]-delta[1]*edge[0],0) AS den) d
        )
        SELECT c.*, greatest(coalesce(rm.floor_z,rs.floor_z),coalesce(sm.floor_z,ss.floor_z)) AS bottom,
            least(coalesce(rm.ceiling_z,rs.ceiling_z),coalesce(sm.ceiling_z,ss.ceiling_z)) AS top
        FROM contacts c JOIN doom.sectors rs ON rs.level=p AND rs.id=c.r
        LEFT JOIN doom.sectors ss ON ss.level=p AND ss.id=c.s
        LEFT JOIN doom.movers rm ON rm.game=g AND rm.sector=c.r
        LEFT JOIN doom.movers sm ON sm.game=g AND sm.sector=c.s
        WHERE c.k BETWEEN 0 AND 1 AND c.u BETWEEN 0 AND 1
        ORDER BY c.k,(c.s IS NULL) DESC,c.id
    LOOP
        CONTINUE WHEN direction<>hit.r AND direction IS DISTINCT FROM hit.s;
        sector := direction; line := hit.id; t := hit.k;
        other := CASE WHEN direction=hit.r THEN hit.s ELSE hit.r END;
        blocked := other IS NULL OR eye<hit.bottom OR eye>=hit.top;
        RETURN NEXT;
        EXIT WHEN blocked;
        direction := other;
    END LOOP;
END;
$$;

CREATE TYPE doom.location AS (pos point,sector int,z float8);
CREATE FUNCTION doom.try_move(p bigint,body doom.actors,next_pos point) RETURNS doom.location
LANGUAGE plpgsql STABLE STRICT AS $$
DECLARE
    obstacle doom.boundary;
    tile doom.blockmap;
    dest int := body.sector;
    floor_at int;
    bottom int;
    top_z int;
    solid boolean;
    path lseg:=lseg(body.pos,next_pos);
    seen int[]:='{}';
BEGIN
    FOR tile IN SELECT * FROM doom.blockmap b WHERE b.level=p
        AND b.x BETWEEN ceil((least(body.pos[0],next_pos[0])-body.radius)/128)::int-1
            AND floor((greatest(body.pos[0],next_pos[0])+body.radius)/128)::int
        AND b.y BETWEEN ceil((least(body.pos[1],next_pos[1])-body.radius)/128)::int-1
            AND floor((greatest(body.pos[1],next_pos[1])+body.radius)/128)::int LOOP
        FOREACH obstacle IN ARRAY tile.walls LOOP
            CONTINUE WHEN path <-> obstacle.segment > body.radius OR obstacle.id=ANY(seen);
            seen:=array_append(seen,obstacle.id);
            solid:=obstacle.back IS NULL OR (obstacle.flags & 1)<>0 OR (body.role='monster' AND (obstacle.flags&2)<>0);
            IF NOT solid THEN
                SELECT max(coalesce(m.floor_z,s.floor_z)),min(coalesce(m.ceiling_z,s.ceiling_z)) INTO bottom,top_z
                FROM doom.sectors s LEFT JOIN doom.movers m ON m.game=body.game AND m.sector=s.id
                WHERE s.level=p AND s.id IN (obstacle.front,obstacle.back);
                solid:=bottom>body.z+24 OR top_z-greatest(body.z,bottom)<body.height;
            END IF;
            IF solid THEN
                IF path ?# obstacle.segment OR (next_pos <-> obstacle.segment) <= (body.pos <-> obstacle.segment) THEN RETURN NULL; END IF;
            ELSIF path ?# obstacle.segment THEN
                dest:=doom.sector_at(p,next_pos);
                IF dest IS NULL THEN RETURN NULL; END IF;
            END IF;
        END LOOP;
    END LOOP;
    IF EXISTS (SELECT FROM doom.actors a WHERE a.game=body.game AND a.id<>body.id AND a.health>0
        AND a.role IN ('player','monster','barrel')
        AND a.cell_x BETWEEN floor((next_pos[0]-body.radius-32)/128)::int AND floor((next_pos[0]+body.radius+32)/128)::int
        AND a.cell_y BETWEEN floor((next_pos[1]-body.radius-32)/128)::int AND floor((next_pos[1]+body.radius+32)/128)::int
        AND body.z<a.z+a.height AND body.z+body.height>a.z AND (a.pos<->next_pos)<a.radius+body.radius
        AND (a.pos<->next_pos)<=(a.pos<->body.pos)) THEN RETURN NULL; END IF;
    SELECT coalesce(m.floor_z,s.floor_z) INTO floor_at FROM doom.sectors s
    LEFT JOIN doom.movers m ON m.game=body.game AND m.sector=s.id WHERE s.level=p AND s.id=dest;
    RETURN (next_pos,dest,floor_at)::doom.location;
END;
$$;
