CREATE TABLE doom.levels (
    level_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL CHECK (name <> ''),
    step_height integer NOT NULL DEFAULT 24 CHECK (step_height >= 0)
);

CREATE TABLE doom.sectors (
    level_id bigint NOT NULL REFERENCES doom.levels ON DELETE CASCADE,
    sector_id integer NOT NULL CHECK (sector_id >= 0),
    floor_height integer NOT NULL,
    ceiling_height integer NOT NULL CHECK (ceiling_height >= floor_height),
    light_level integer NOT NULL DEFAULT 160 CHECK (light_level BETWEEN 0 AND 255),
    floor_material text,
    ceiling_material text,
    special integer NOT NULL DEFAULT 0,
    tag integer NOT NULL DEFAULT 0,
    PRIMARY KEY (level_id, sector_id)
);

CREATE INDEX sectors_tag ON doom.sectors (level_id, tag) WHERE tag <> 0;

CREATE TABLE doom.wad_vertices (
    level_id bigint NOT NULL REFERENCES doom.levels ON DELETE CASCADE,
    vertex_id integer NOT NULL,
    x integer NOT NULL,
    y integer NOT NULL,
    PRIMARY KEY (level_id, vertex_id)
);

CREATE TABLE doom.wad_sidedefs (
    level_id bigint NOT NULL,
    side_id integer NOT NULL,
    sector_id integer NOT NULL,
    x_offset integer NOT NULL DEFAULT 0,
    y_offset integer NOT NULL DEFAULT 0,
    upper_material text,
    lower_material text,
    middle_material text,
    PRIMARY KEY (level_id, side_id),
    FOREIGN KEY (level_id, sector_id) REFERENCES doom.sectors ON DELETE CASCADE
);

CREATE TABLE doom.lines (
    level_id bigint NOT NULL,
    line_id integer NOT NULL CHECK (line_id >= 0),
    first_vertex_id integer,
    second_vertex_id integer,
    x1 integer NOT NULL,
    y1 integer NOT NULL,
    x2 integer NOT NULL,
    y2 integer NOT NULL,
    front_sector_id integer NOT NULL,
    back_sector_id integer,
    front_side_id integer,
    back_side_id integer,
    flags integer NOT NULL DEFAULT 0,
    special integer NOT NULL DEFAULT 0,
    tag integer NOT NULL DEFAULT 0,
    blocking boolean NOT NULL DEFAULT false,
    CHECK (x1 <> x2 OR y1 <> y2),
    PRIMARY KEY (level_id, line_id),
    FOREIGN KEY (level_id, front_sector_id) REFERENCES doom.sectors ON DELETE CASCADE,
    FOREIGN KEY (level_id, back_sector_id) REFERENCES doom.sectors ON DELETE CASCADE,
    FOREIGN KEY (level_id, front_side_id) REFERENCES doom.wad_sidedefs ON DELETE CASCADE,
    FOREIGN KEY (level_id, back_side_id) REFERENCES doom.wad_sidedefs ON DELETE CASCADE,
    FOREIGN KEY (level_id, first_vertex_id) REFERENCES doom.wad_vertices ON DELETE CASCADE,
    FOREIGN KEY (level_id, second_vertex_id) REFERENCES doom.wad_vertices ON DELETE CASCADE
);

CREATE INDEX lines_front_sector ON doom.lines (level_id, front_sector_id);
CREATE INDEX lines_back_sector ON doom.lines (level_id, back_sector_id);
CREATE INDEX lines_bounds ON doom.lines USING gist (box(point(x1, y1), point(x2, y2)));

CREATE VIEW doom.line_surfaces AS
SELECT line.level_id, line.line_id, face.is_back, side.x_offset, side.y_offset,
       side.upper_material, side.lower_material, side.middle_material
FROM doom.lines AS line
CROSS JOIN LATERAL (VALUES (false, line.front_side_id), (true, line.back_side_id)) AS face(is_back, side_id)
JOIN doom.wad_sidedefs AS side ON side.level_id = line.level_id AND side.side_id = face.side_id;

CREATE VIEW doom.wad_line_actions AS
SELECT level_id, line_id, special, tag FROM doom.lines WHERE special <> 0 OR tag <> 0;

CREATE VIEW doom.wad_sector_properties AS
SELECT level_id, sector_id, special, tag FROM doom.sectors WHERE special <> 0 OR tag <> 0;

CREATE TABLE doom.wad_segs (
    level_id bigint NOT NULL,
    seg_id integer NOT NULL,
    first_vertex_id integer NOT NULL,
    second_vertex_id integer NOT NULL,
    x1 integer NOT NULL,
    y1 integer NOT NULL,
    x2 integer NOT NULL,
    y2 integer NOT NULL,
    line_id integer NOT NULL,
    side integer NOT NULL CHECK (side IN (0, 1)),
    side_id integer NOT NULL,
    front_sector_id integer NOT NULL,
    back_sector_id integer,
    angle integer NOT NULL,
    "offset" integer NOT NULL,
    PRIMARY KEY (level_id, seg_id),
    FOREIGN KEY (level_id, line_id) REFERENCES doom.lines ON DELETE CASCADE
);

CREATE TABLE doom.wad_subsectors (
    level_id bigint NOT NULL,
    subsector_id integer NOT NULL,
    first_seg_id integer NOT NULL,
    seg_count integer NOT NULL CHECK (seg_count > 0),
    sector_id integer NOT NULL,
    PRIMARY KEY (level_id, subsector_id),
    FOREIGN KEY (level_id, sector_id) REFERENCES doom.sectors ON DELETE CASCADE
);

CREATE TABLE doom.wad_bsp_nodes (
    level_id bigint NOT NULL REFERENCES doom.levels ON DELETE CASCADE,
    node_id integer NOT NULL,
    x integer NOT NULL,
    y integer NOT NULL,
    dx integer NOT NULL,
    dy integer NOT NULL,
    -- A negative child stores the bitwise complement of a subsector ID.
    right_child integer NOT NULL,
    left_child integer NOT NULL,
    right_top integer NOT NULL,
    right_bottom integer NOT NULL,
    right_left integer NOT NULL,
    right_right integer NOT NULL,
    left_top integer NOT NULL,
    left_bottom integer NOT NULL,
    left_left integer NOT NULL,
    left_right integer NOT NULL,
    PRIMARY KEY (level_id, node_id)
);

CREATE TABLE doom.wad_blockmaps (
    level_id bigint PRIMARY KEY REFERENCES doom.levels ON DELETE CASCADE,
    origin_x integer NOT NULL,
    origin_y integer NOT NULL,
    width integer NOT NULL CHECK (width > 0),
    height integer NOT NULL CHECK (height > 0)
);

CREATE TABLE doom.wad_line_blocks (
    level_id bigint NOT NULL REFERENCES doom.wad_blockmaps ON DELETE CASCADE,
    block_x integer NOT NULL,
    block_y integer NOT NULL,
    line_ids integer[] NOT NULL,
    PRIMARY KEY (level_id, block_x, block_y)
);

CREATE TABLE doom.wad_sector_lookup (
    level_id bigint PRIMARY KEY REFERENCES doom.levels ON DELETE CASCADE,
    nodes integer[] NOT NULL,
    leaf_sectors integer[] NOT NULL
);

CREATE TABLE doom.level_things (
    level_id bigint NOT NULL REFERENCES doom.levels ON DELETE CASCADE,
    thing_id integer NOT NULL CHECK (thing_id >= 0),
    x integer NOT NULL,
    y integer NOT NULL,
    angle_deg integer NOT NULL,
    type_code integer NOT NULL CHECK (type_code BETWEEN 0 AND 65535),
    flags integer NOT NULL CHECK (flags BETWEEN 0 AND 65535),
    sector_id integer,
    PRIMARY KEY (level_id, thing_id),
    FOREIGN KEY (level_id, sector_id) REFERENCES doom.sectors ON DELETE CASCADE
);

CREATE TABLE doom.level_palettes (
    level_id bigint PRIMARY KEY REFERENCES doom.levels ON DELETE CASCADE,
    palette bytea NOT NULL CHECK (octet_length(palette) = 768),
    playpal bytea NOT NULL CHECK (octet_length(playpal) >= 768 AND octet_length(playpal) % 768 = 0),
    colormap bytea NOT NULL CHECK (octet_length(colormap) >= 256 AND octet_length(colormap) % 256 = 0)
);

CREATE TABLE doom.level_materials (
    level_id bigint NOT NULL REFERENCES doom.levels ON DELETE CASCADE,
    surface_kind text NOT NULL CHECK (surface_kind IN ('wall', 'flat', 'sprite')),
    name text NOT NULL CHECK (name <> ''),
    width integer NOT NULL CHECK (width > 0),
    height integer NOT NULL CHECK (height > 0),
    left_offset integer NOT NULL DEFAULT 0,
    top_offset integer NOT NULL DEFAULT 0,
    -- Walls and sprites are column-major. Flats retain the WAD's row-major bytes.
    pixels bytea NOT NULL CHECK (octet_length(pixels) = width::bigint * height),
    coverage bytea NOT NULL CHECK (octet_length(coverage) = width::bigint * height),
    opaque boolean GENERATED ALWAYS AS (position('\x00'::bytea IN coverage) = 0) STORED,
    PRIMARY KEY (level_id, surface_kind, name)
);
