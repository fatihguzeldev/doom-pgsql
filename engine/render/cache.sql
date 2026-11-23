CREATE FUNCTION doom.anchor_view(g bigint) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    body doom.actors;
    p bigint;
    rev bigint;
    geometry_key text;
    static_frame record;
BEGIN
    SELECT * INTO STRICT body FROM doom.actors WHERE game=g AND id=-1;
    SELECT l.id,l.revision INTO STRICT p,rev FROM doom.games game JOIN doom.levels l ON l.id=game.level WHERE game.id=g;
    geometry_key:=doom.opening_key(g);
    IF EXISTS(SELECT FROM doom.view_cache WHERE game=g AND revision=rev AND sector=body.sector AND x=body.pos[0]
        AND y=body.pos[1] AND z=body.z AND yaw=body.yaw AND openings=geometry_key) THEN RETURN; END IF;
    SELECT * INTO STRICT static_frame FROM doom.raster(g,(SELECT epoch FROM doom.games WHERE id=g),0,true);
    INSERT INTO doom.view_cache(game,revision,x,y,z,yaw,sector,openings,background,illumination,depths,far_z)
    VALUES(g,rev,body.pos[0],body.pos[1],body.z,body.yaw,body.sector,geometry_key,static_frame.pixels,
        static_frame.shades,static_frame.scene_depth,(SELECT max(z) FROM unnest(static_frame.scene_depth)z))
    ON CONFLICT(game) DO UPDATE SET revision=excluded.revision,x=excluded.x,y=excluded.y,z=excluded.z,
        yaw=excluded.yaw,sector=excluded.sector,openings=excluded.openings,background=excluded.background,
        illumination=excluded.illumination,depths=excluded.depths,far_z=excluded.far_z;
    DELETE FROM doom.view_edges WHERE game=g;
    -- Include the entire yaw bucket, including its extremes. A segment is discarded
    -- only if both endpoints lie outside the same widened frustum half-plane.
    INSERT INTO doom.view_edges
    SELECT g,bucket,coalesce(array_agg(e ORDER BY e.line) FILTER(WHERE
        greatest(z0*spread+r0,z1*spread+r1)>=-1e-7 AND greatest(z0*spread-r0,z1*spread-r1)>=-1e-7),'{}'::doom.edge[])
    FROM generate_series(0,15)bucket CROSS JOIN doom.mesh m CROSS JOIN LATERAL unnest(m.edges)e,
        LATERAL(SELECT cos(bucket*pi()/8) AS fx,sin(bucket*pi()/8) AS fy,tan(5*pi()/16) AS spread) camera,
        LATERAL(SELECT e.a[0]-body.pos[0] AS origin_dx,e.a[1]-body.pos[1] AS origin_dy) start,
        LATERAL(SELECT origin_dx*fx+origin_dy*fy AS z0,origin_dx*fy-origin_dy*fx AS r0,(origin_dx+e.dx)*fx+(origin_dy+e.dy)*fy AS z1,
            (origin_dx+e.dx)*fy-(origin_dy+e.dy)*fx AS r1) ends
    WHERE m.level=p AND m.sector=body.sector GROUP BY bucket;
END;
$$;
CREATE FUNCTION doom.anchor_stationary_game() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM doom.anchor_view(NEW.id);
    RETURN NULL;
END;
$$;
CREATE TRIGGER anchor_stationary AFTER UPDATE OF still_tics ON doom.games
FOR EACH ROW WHEN (NEW.still_tics=4 AND OLD.still_tics<>4) EXECUTE FUNCTION doom.anchor_stationary_game();
