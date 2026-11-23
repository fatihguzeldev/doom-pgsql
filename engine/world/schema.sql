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
