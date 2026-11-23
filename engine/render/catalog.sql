CREATE TYPE doom.projection AS (
    wall doom.edge, lo int, hi int, z0 float8, r0 float8, dz float8, dr float8, k float8,
    inv0 float8, inv_step float8
);
CREATE TYPE doom.aperture AS (sector int, lo int, hi int, entry int, inv0 float8, inv_step float8);

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

-- kinds: 0 plane (v is world height), 1 solid wall, 2 sky, 3 masked wall, 4 sprite.
CREATE TYPE doom.stroke AS (
    x int,y0 int,y1 int,kind int,art int,u float8,v float8,dv float8,depth float8,light int
);
-- a moving door invalidates the background even when the camera is still.
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
CREATE TYPE doom.tile AS (w int,h int,pixels bytea,mask bytea,stretched bytea,quads bytea,quad_start int,column_ids int[],posts doom.sprite_posts);
