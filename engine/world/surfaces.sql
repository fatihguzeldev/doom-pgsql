ALTER TABLE doom.sectors
    ADD COLUMN floor_material text,
    ADD COLUMN ceiling_material text;

CREATE TABLE doom.line_surfaces (
    level_id bigint NOT NULL,
    line_id integer NOT NULL,
    is_back boolean NOT NULL,
    x_offset integer NOT NULL DEFAULT 0,
    y_offset integer NOT NULL DEFAULT 0,
    upper_material text,
    lower_material text,
    middle_material text,
    PRIMARY KEY (level_id, line_id, is_back),
    FOREIGN KEY (level_id, line_id) REFERENCES doom.lines ON DELETE CASCADE
);
