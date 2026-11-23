CREATE TYPE doom.edge AS (
    line int, dest int, a point, dx float8, dy float8, len float8,
    flags int, special int, tag int, u int, v int, upper_id int, lower_id int, mid_id int, upper_h int, mid_h int
);
CREATE TABLE doom.mesh (
    level bigint REFERENCES doom.levels ON DELETE CASCADE, sector int,
    bounds box NOT NULL, edges doom.edge[] NOT NULL, floor_id int, ceiling_id int,
    sky boolean NOT NULL, component int,
    PRIMARY KEY(level,sector)
);
CREATE INDEX mesh_bounds ON doom.mesh USING gist(bounds);

-- Enumerate closed 128-unit grid squares touched by a segment, including both
-- sides of an edge or corner. Work scales with its length along the major axis.
CREATE FUNCTION doom.cells(a point,b point,padding float8 DEFAULT 0)
RETURNS TABLE(x int,y int) LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
    WITH axes AS (SELECT abs(b[0]-a[0])>=abs(b[1]-a[1]) AS horizontal),
    coords AS (SELECT horizontal, CASE WHEN horizontal THEN a[0] ELSE a[1] END AS u,
        CASE WHEN horizontal THEN a[1] ELSE a[0] END AS v,
        CASE WHEN horizontal THEN b[0] ELSE b[1] END AS s,
        CASE WHEN horizontal THEN b[1] ELSE b[0] END AS t FROM axes),
    sweep AS (SELECT *,least(u,s) AS lo,greatest(u,s) AS hi,
        CASE WHEN u=s THEN 0 ELSE (t-v)/(s-u) END AS slope FROM coords)
    SELECT CASE WHEN horizontal THEN i ELSE j END,CASE WHEN horizontal THEN j ELSE i END
    FROM sweep, LATERAL generate_series(ceil((lo-padding)/128)::int-1,floor((hi+padding)/128)::int)i,
    LATERAL (SELECT v+(greatest(lo,128.*i-padding)-u)*slope AS v0,
                    v+(least(hi,128.*(i+1)+padding)-u)*slope AS v1) ends,
    LATERAL generate_series(ceil((least(v0,v1)-padding)/128)::int-1,floor((greatest(v0,v1)+padding)/128)::int)j;
$$;
CREATE TYPE doom.boundary AS (id int, segment lseg, front int, back int, flags int);
CREATE TABLE doom.blockmap (
    level bigint REFERENCES doom.levels ON DELETE CASCADE, x int,y int,walls doom.boundary[] NOT NULL,
    PRIMARY KEY(level,x,y)
);

CREATE FUNCTION doom.compile_level(p bigint) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    -- Serializes rebuilds of the same level with publication of their revision.
    PERFORM 1 FROM doom.levels WHERE id=p FOR UPDATE;
    DELETE FROM doom.mesh WHERE level=p;
    WITH directed AS (
        SELECT l.id,side.sector,opposite.sector AS dest,start_pt,finish_pt,l.flags,l.special,l.tag,side.u,side.v,
            hi.id AS upper_id,lo.id AS lower_id,mid.id AS mid_id, hi.h AS upper_h,mid.h AS mid_h
        FROM doom.lines l CROSS JOIN LATERAL (VALUES(l.front,l.back,l.a,l.b),(l.back,l.front,l.b,l.a)) f(s,o,start_pt,finish_pt)
        JOIN doom.sides side ON side.level=p AND side.id=f.s
        LEFT JOIN doom.sides opposite ON opposite.level=p AND opposite.id=f.o
        LEFT JOIN doom.art hi ON (hi.level,hi.kind,hi.name)=(p,'wall',side.upper_tex)
        LEFT JOIN doom.art lo ON (lo.level,lo.kind,lo.name)=(p,'wall',side.lower_tex)
        LEFT JOIN doom.art mid ON (mid.level,mid.kind,mid.name)=(p,'wall',side.middle_tex)
        WHERE l.level=p AND NOT l.a~=l.b
    ), sectors AS (
        SELECT sector,box(point(min(least(start_pt[0],finish_pt[0])),min(least(start_pt[1],finish_pt[1]))),
                          point(max(greatest(start_pt[0],finish_pt[0])),max(greatest(start_pt[1],finish_pt[1])))) AS bounds,
            array_agg(ROW(id,dest,start_pt,finish_pt[0]-start_pt[0],finish_pt[1]-start_pt[1],start_pt<->finish_pt,
                flags,special,tag,u,v,upper_id,lower_id,mid_id,upper_h,mid_h)::doom.edge ORDER BY id) AS edges
        FROM directed GROUP BY sector)
    INSERT INTO doom.mesh(level,sector,bounds,edges,floor_id,ceiling_id,sky)
    SELECT p,s.id,d.bounds,d.edges,f.id,c.id,s.ceiling_tex='F_SKY1'
    FROM doom.sectors s JOIN sectors d ON d.sector=s.id JOIN doom.levels l ON l.id=p
    LEFT JOIN doom.art f ON (f.level,f.kind,f.name)=(p,'flat',s.floor_tex)
    LEFT JOIN doom.art c ON c.level=p AND c.kind=CASE WHEN s.ceiling_tex='F_SKY1' THEN 'wall' ELSE 'flat' END::doom.surface
        AND c.name=CASE WHEN s.ceiling_tex='F_SKY1' THEN doom.sky_name(l.name) ELSE s.ceiling_tex END
    WHERE s.level=p;
    -- A closed door can subsequently open. Connectivity includes all two-sided portals.
    WITH RECURSIVE links AS MATERIALIZED (
        SELECT DISTINCT m.sector,e.dest FROM doom.mesh m,unnest(m.edges)e WHERE m.level=p AND e.dest IS NOT NULL
    ), reach(root,id) AS (
        SELECT m.sector,m.sector FROM doom.mesh m WHERE level=p
        UNION SELECT r.root,l.dest FROM reach r JOIN links l ON l.sector=r.id)
    UPDATE doom.mesh m SET component=c.root FROM (SELECT id,min(root) AS root FROM reach GROUP BY id)c
    WHERE m.level=p AND m.sector=c.id;
    DELETE FROM doom.blockmap WHERE level=p;
    INSERT INTO doom.blockmap
    SELECT p,c.x,c.y,array_agg(ROW(l.id,lseg(l.a,l.b),f.sector,b.sector,l.flags)::doom.boundary ORDER BY l.id)
    FROM doom.lines l JOIN doom.sides f ON f.level=p AND f.id=l.front
    LEFT JOIN doom.sides b ON b.level=p AND b.id=l.back
    CROSS JOIN LATERAL doom.cells(l.a,l.b)c WHERE l.level=p GROUP BY c.x,c.y;
    UPDATE doom.levels SET revision=revision+1 WHERE id=p;
END;
$$;

CREATE FUNCTION doom.sector_at(p bigint, pos point) RETURNS int LANGUAGE sql STABLE STRICT AS $$
    SELECT m.sector FROM doom.mesh m WHERE m.level=p AND m.bounds @> pos AND
    (SELECT count(*)%2=1 FROM unnest(m.edges)e
      WHERE (e.a[1]>pos[1]) <> (e.a[1]+e.dy>pos[1])
        AND pos[0] < e.a[0]+(pos[1]-e.a[1])*e.dx/nullif(e.dy,0))
    ORDER BY m.sector LIMIT 1;
$$;

-- Transition tables coalesce a multi-row editor operation into one compile per level.
CREATE FUNCTION doom.rebuild_edited() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    ids bigint[];
    p bigint;
BEGIN
    IF TG_OP='INSERT' THEN SELECT array_agg(DISTINCT level) INTO ids FROM after_edit;
    ELSIF TG_OP='DELETE' THEN SELECT array_agg(DISTINCT level) INTO ids FROM before_edit;
    ELSE SELECT array_agg(level ORDER BY level) INTO ids FROM
        (SELECT level FROM before_edit UNION SELECT level FROM after_edit) edited;
    END IF;
    FOR p IN SELECT id FROM doom.levels WHERE ready AND id=ANY(ids) ORDER BY id FOR UPDATE LOOP
        UPDATE doom.levels SET reject=NULL WHERE id=p;
        PERFORM doom.compile_level(p);
    END LOOP;
    RETURN NULL;
END;
$$;
DO $$
DECLARE
    target text;
BEGIN
    FOREACH target IN ARRAY ARRAY['lines','sides','sectors','art'] LOOP
        EXECUTE format('CREATE TRIGGER compile_insert AFTER INSERT ON doom.%I REFERENCING NEW TABLE AS after_edit FOR EACH STATEMENT EXECUTE FUNCTION doom.rebuild_edited()',target);
        EXECUTE format('CREATE TRIGGER compile_delete AFTER DELETE ON doom.%I REFERENCING OLD TABLE AS before_edit FOR EACH STATEMENT EXECUTE FUNCTION doom.rebuild_edited()',target);
        EXECUTE format('CREATE TRIGGER compile_update AFTER UPDATE ON doom.%I REFERENCING NEW TABLE AS after_edit OLD TABLE AS before_edit FOR EACH STATEMENT EXECUTE FUNCTION doom.rebuild_edited()',target);
    END LOOP;
END;
$$;
