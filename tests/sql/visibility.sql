-- the nearest ray hit in each column is the reference for the portal sweep.
DO $$
DECLARE
    edges doom.edge[];
    win doom.aperture;
    heading float8;
    mismatches int;
BEGIN
    SELECT array_agg(ROW(id,NULL,a,b[0]-a[0],b[1]-a[1],a<->b,0,0,0,0,0,NULL,NULL,1,NULL,1)::doom.edge)
    INTO edges FROM (VALUES
        (1,point(80,135),point(170,-140)),(2,point(170,140),point(70,-130)),
        (3,point(55,4),point(55,-2)),(4,point(-2,25),point(65,23)),(5,point(100,-30),point(70,-105))
    ) authored(id,a,b);
    FOREACH heading IN ARRAY ARRAY[-0.71,-0.07,0,0.38,0.84]::float8[] LOOP
        FOREACH win IN ARRAY ARRAY[ROW(0,0,159,-1,0,0)::doom.aperture,
            ROW(0,11,140,0,1./85.,0)::doom.aperture] LOOP
            WITH actual AS (
                SELECT x,(v.wall).line AS id FROM doom.visible(edges,win,point(0,0),cos(heading),sin(heading))v,
                    LATERAL generate_series(v.lo,v.hi)x
            ), rays AS (SELECT x,cos(heading)+sin(heading)*(x-79.5)/80 AS dx,
                    sin(heading)-cos(heading)*(x-79.5)/80 AS dy FROM generate_series(win.lo,win.hi)x),
            hits AS (
                SELECT r.x,e.line AS id,(e.a[0]*e.dy-e.a[1]*e.dx)/d AS z,
                    (e.a[0]*r.dy-e.a[1]*r.dx)/d AS u
                FROM rays r,unnest(edges)e,LATERAL(SELECT nullif(r.dx*e.dy-r.dy*e.dx,0) AS d) axis WHERE d<0
            ), expected AS (
                SELECT DISTINCT ON (x) x,id FROM hits WHERE z>=0.001 AND u>=0 AND u<1
                    AND (win.entry<0 OR 1/z<win.inv0+win.inv_step*x) ORDER BY x,z,id
            )
            SELECT count(*) INTO mismatches FROM expected FULL JOIN actual USING(x,id)
            WHERE expected.id IS NULL OR actual.id IS NULL;
            ASSERT mismatches=0,format('portal sweep differs at %s pixels, heading %s',mismatches,heading);
        END LOOP;
    END LOOP;
END;
$$;
