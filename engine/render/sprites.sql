CREATE OR REPLACE FUNCTION doom.sprite_strokes(p bigint,g bigint,body doom.actors,fx float8,fy float8,far_z float8,cam doom.viewports)
RETURNS SETOF doom.stroke LANGUAGE sql STABLE AS $$
    WITH visible_actors AS MATERIALIZED (
        SELECT a.sector,a.art,a.z,im.h,im.origin_y,loc.depth,
            cam.cx+(loc.rightward-im.origin_x)*cam.focal/loc.depth AS left_x,
            cam.cx+(loc.rightward-im.origin_x+im.w)*cam.focal/loc.depth AS right_x
        FROM doom.actors a JOIN doom.art im ON im.id=a.art,
        LATERAL (SELECT (a.pos[0]-body.pos[0])*fx+(a.pos[1]-body.pos[1])*fy AS depth,
                        (a.pos[0]-body.pos[0])*fy-(a.pos[1]-body.pos[1])*fx AS rightward) loc
        WHERE a.game=g AND a.id<>-1 AND a.health>0 AND loc.depth>0.001 AND loc.depth<=far_z
          AND cam.cx+(loc.rightward-im.origin_x)*cam.focal/nullif(loc.depth,0)<=cam.w-1
          AND cam.cx+(loc.rightward-im.origin_x+im.w)*cam.focal/nullif(loc.depth,0)>0
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
        SELECT *,greatest(0,least(cam.h,ceil(cam.cy+(body.z+41-top)*cam.focal/depth)))::int AS y0,
            greatest(0,least(cam.h,ceil(cam.cy+(body.z+41-bottom)*cam.focal/depth)))::int AS y1 FROM clipped
    )
    SELECT x,y0,y1,4,art,(x-left_x)*depth/cam.focal,z+origin_y-body.z-41+(y0-cam.cy)*depth/cam.focal,depth/cam.focal,depth,light
    FROM screen,LATERAL generate_series(greatest(0,ceil(left_x))::int,least(cam.w-1,ceil(right_x)-1)::int)x
    WHERE y0<y1;
$$;

CREATE OR REPLACE FUNCTION doom.sprite_strokes(p bigint,g bigint,body doom.actors,fx float8,fy float8,far_z float8)
RETURNS SETOF doom.stroke LANGUAGE sql STABLE  AS $$
    SELECT f.* FROM doom.viewports cam CROSS JOIN LATERAL doom.sprite_strokes(p,g,body,fx,fy,far_z,cam) f WHERE cam.w=160;
$$;
