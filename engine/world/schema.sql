CREATE TABLE doom.levels (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL,
    ready boolean NOT NULL DEFAULT false,
    palette bytea NOT NULL CHECK (length(palette)=768),
    lighting bytea NOT NULL CHECK (length(lighting)>=256 AND length(lighting)%256=0),
    reject bytea,
    sector_count int NOT NULL,
    revision bigint NOT NULL DEFAULT 1,
    geometry_revision bigint NOT NULL DEFAULT 0
);

CREATE TYPE doom.surface AS ENUM ('wall','flat','sprite');
-- Every four samples at a step below 2/3 draw at most three consecutive
-- texels. This 16-byte word contains every possible four-sample substring.
CREATE FUNCTION doom.wall_quads(data bytea,w int,h int) RETURNS bytea LANGUAGE sql IMMUTABLE STRICT AS $$
    WITH cols AS MATERIALIZED (
        SELECT x,substring(data FROM 1+x*h FOR h) AS col FROM generate_series(0,w-1)x
    ), padded AS MATERIALIZED (
        SELECT x,col||substring(col||col FOR 2) AS col FROM cols
    )
    SELECT decode(regexp_replace(encode(string_agg(substring(col FROM y FOR 3),''::bytea ORDER BY x,y),'hex'),
        '(..)(..)(..)','\1\1\1\1\2\2\2\1\2\2\3\1\1\2\3\3','g'),'hex')
    FROM padded,generate_series(1,h)y;
$$;
-- Ordinals are zero-based in the texture, one-based in the SQL arrays.
CREATE FUNCTION doom.wall_column_ids(pixels bytea,mask bytea,w int,h int) RETURNS int[]
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    WITH ids AS (
        SELECT x,min(x) OVER (PARTITION BY substring(pixels FROM 1+x*h FOR h),
            substring(mask FROM 1+x*h FOR h)) AS id FROM generate_series(0,w-1)x
    )
    SELECT CASE WHEN bool_or(x<>id) THEN array_agg(id ORDER BY x) END FROM ids;
$$;

CREATE TYPE doom.sprite_posts AS (offsets int[],runs int4range[]);
CREATE FUNCTION doom.sprite_posts(mask bytea,w int,h int) RETURNS doom.sprite_posts
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
    WITH runs AS MATERIALIZED (
        SELECT x,int4range(min(y),max(y)+1) AS span FROM (
            SELECT x,y,y-row_number() OVER (PARTITION BY x ORDER BY y) AS group_id
            FROM generate_series(0,w-1)x,generate_series(0,h-1)y WHERE get_byte(mask,x*h+y)<>0
        ) opaque GROUP BY x,group_id
    ), offsets AS (
        SELECT x,1+sum(count(span)) OVER (ORDER BY x ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS stop
        FROM generate_series(0,w-1)x LEFT JOIN runs USING(x) GROUP BY x
    )
    SELECT ARRAY[1]||ARRAY(SELECT stop::int FROM offsets ORDER BY x),
        ARRAY(SELECT span FROM runs ORDER BY x,span);
$$;

CREATE TABLE doom.art (
    id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    level bigint NOT NULL REFERENCES doom.levels ON DELETE CASCADE,
    kind doom.surface NOT NULL,
    name text NOT NULL,
    w int NOT NULL CHECK (w>0), h int NOT NULL CHECK (h>0),
    origin_x int NOT NULL DEFAULT 0, origin_y int NOT NULL DEFAULT 0,
    pixels bytea NOT NULL CHECK (length(pixels)=w::bigint*h),
    stretched bytea GENERATED ALWAYS AS (CASE WHEN kind='wall' THEN
        decode(regexp_replace(encode(pixels,'hex'),'(..)','\1\1','g'),'hex') END) STORED,
    quads bytea GENERATED ALWAYS AS (CASE WHEN kind='wall' AND (h&(h-1))=0 AND w::bigint*h<=65536
        THEN doom.wall_quads(pixels,w,h) END) STORED,
    mask bytea CHECK (length(mask)=length(pixels)),
    column_ids int[] GENERATED ALWAYS AS (CASE WHEN kind='wall' THEN doom.wall_column_ids(pixels,mask,w,h) END) STORED,
    posts doom.sprite_posts GENERATED ALWAYS AS (CASE WHEN kind='sprite' THEN doom.sprite_posts(mask,w,h) END) STORED,
    UNIQUE(level,kind,name)
);

-- Uncompressed TOAST storage lets substring fetch just the visible columns.
ALTER TABLE doom.art ALTER COLUMN quads SET STORAGE EXTERNAL;

CREATE TABLE doom.sectors (
    level bigint REFERENCES doom.levels ON DELETE CASCADE, id int CHECK(id BETWEEN 0 AND 65535),
    floor_z int NOT NULL, ceiling_z int NOT NULL CHECK (ceiling_z>=floor_z),
    floor_tex text NOT NULL, ceiling_tex text NOT NULL,
    light int NOT NULL CHECK (light BETWEEN 0 AND 255),
    special int NOT NULL, tag int NOT NULL,
    PRIMARY KEY(level,id)
);
CREATE TABLE doom.sides (
    level bigint NOT NULL, id int, sector int NOT NULL,
    u int NOT NULL, v int NOT NULL, upper_tex text, lower_tex text, middle_tex text,
    PRIMARY KEY(level,id), FOREIGN KEY(level,sector) REFERENCES doom.sectors ON DELETE CASCADE
);
CREATE TABLE doom.lines (
    level bigint NOT NULL, id int, a point NOT NULL, b point NOT NULL,
    front int NOT NULL, back int, flags int NOT NULL, special int NOT NULL, tag int NOT NULL,
    PRIMARY KEY(level,id),
    FOREIGN KEY(level,front) REFERENCES doom.sides ON DELETE CASCADE,
    FOREIGN KEY(level,back) REFERENCES doom.sides ON DELETE CASCADE
);
CREATE INDEX lines_bounds ON doom.lines USING gist (box(a,b));
CREATE TABLE doom.spawns (
    level bigint REFERENCES doom.levels ON DELETE CASCADE, id int, pos point NOT NULL,
    angle int NOT NULL, thing int NOT NULL, flags int NOT NULL,
    PRIMARY KEY(level,id)
);
