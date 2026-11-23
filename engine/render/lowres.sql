CREATE TABLE doom.viewports (
    w int PRIMARY KEY, h int NOT NULL, cx float8 NOT NULL, cy float8 NOT NULL, focal float8 NOT NULL,
    sky_step float8 NOT NULL, sky_angles float8[] NOT NULL, row_scale float8[] NOT NULL, shade_runs bytea[] NOT NULL
);
INSERT INTO doom.viewports
SELECT w,h,cx,cy,focal,100.0/h,
    ARRAY(SELECT atan((x-cx)/focal) FROM generate_series(0,w-1)x),
    ARRAY(SELECT focal/abs(y-cy) FROM generate_series(0,h-1)y),
    ARRAY(SELECT decode(repeat(lpad(to_hex(i),2,'0'),h),'hex') FROM generate_series(0,31)i)
FROM (VALUES (160,100),(64,40)) dims(w,h)
CROSS JOIN LATERAL (SELECT (w-1)::float8/2 AS cx,(h-1)::float8/2 AS cy,w::float8/2 AS focal) c;

\ir portals.sql
\ir plane_strip.sql
\ir raster.sql
\ir poll.sql
