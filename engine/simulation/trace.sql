CREATE FUNCTION doom.trace(p bigint,g bigint,origin point,delta point,start_sector int,eye float8)
RETURNS TABLE(line int,sector int,other int,t float8,blocked boolean)
LANGUAGE plpgsql STABLE STRICT AS $$
DECLARE
    hit record;
    direction int := start_sector;
BEGIN
    FOR hit IN
        WITH ids AS MATERIALIZED (
            SELECT DISTINCT unnest(b.lines) AS id FROM doom.cells(origin,origin+delta) c
            JOIN doom.blockmap b ON b.level=p AND b.x=c.x AND b.y=c.y
        ), contacts AS (
            SELECT l.id,l.flags,r.sector AS r,s.sector AS s,
                (ab.v[0]*edge[1]-ab.v[1]*edge[0])/den AS k,(ab.v[0]*delta[1]-ab.v[1]*delta[0])/den AS u
            FROM ids JOIN doom.lines l ON l.level=p AND l.id=ids.id
            JOIN doom.sides r ON r.level=p AND r.id=l.front LEFT JOIN doom.sides s ON s.level=p AND s.id=l.back,
            LATERAL (SELECT l.b-l.a AS edge,l.a-origin AS v) ab,
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
    obstacle record;
    dest int := body.sector;
    floor_at int;
BEGIN
    FOR obstacle IN
        WITH ids AS MATERIALIZED (
            SELECT DISTINCT unnest(b.lines) AS id FROM doom.cells(body.pos,next_pos,body.radius)c
            JOIN doom.blockmap b ON b.level=p AND b.x=c.x AND b.y=c.y
        )
        SELECT lseg(l.a,l.b) AS segment,l.flags,r.sector AS front,s.sector AS back,
            greatest(coalesce(rm.floor_z,rs.floor_z),coalesce(sm.floor_z,ss.floor_z)) AS bottom,
            least(coalesce(rm.ceiling_z,rs.ceiling_z),coalesce(sm.ceiling_z,ss.ceiling_z)) AS top
        FROM ids JOIN doom.lines l ON l.level=p AND l.id=ids.id
        JOIN doom.sides r ON r.level=p AND r.id=l.front LEFT JOIN doom.sides s ON s.level=p AND s.id=l.back
        JOIN doom.sectors rs ON rs.level=p AND rs.id=r.sector LEFT JOIN doom.sectors ss ON ss.level=p AND ss.id=s.sector
        LEFT JOIN doom.movers rm ON rm.game=body.game AND rm.sector=r.sector
        LEFT JOIN doom.movers sm ON sm.game=body.game AND sm.sector=s.sector
        WHERE lseg(body.pos,next_pos) <-> lseg(l.a,l.b) <= body.radius
    LOOP
        IF obstacle.back IS NULL OR (obstacle.flags & 1)<>0 OR
           (body.role='monster' AND (obstacle.flags&2)<>0) OR obstacle.bottom>body.z+24 OR
           obstacle.top-greatest(body.z,obstacle.bottom)<body.height THEN
            IF (next_pos <-> obstacle.segment) <= (body.pos <-> obstacle.segment) THEN RETURN NULL; END IF;
        ELSIF lseg(body.pos,next_pos) ?# obstacle.segment THEN
            dest := doom.sector_at(p,next_pos);
            IF dest IS NULL THEN RETURN NULL; END IF;
        END IF;
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
