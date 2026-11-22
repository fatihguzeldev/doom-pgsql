CREATE TABLE doom.gates (
    level_id bigint NOT NULL,
    sector_id integer NOT NULL,
    closed_ceiling integer NOT NULL,
    open_ceiling integer NOT NULL,
    units_per_tick integer NOT NULL CHECK (units_per_tick > 0),
    CHECK (closed_ceiling < open_ceiling),
    PRIMARY KEY (level_id, sector_id),
    FOREIGN KEY (level_id, sector_id) REFERENCES doom.sectors ON DELETE CASCADE
);

CREATE TABLE doom.gate_controls (
    level_id bigint NOT NULL,
    line_id integer NOT NULL,
    sector_id integer NOT NULL,
    PRIMARY KEY (level_id, line_id),
    FOREIGN KEY (level_id, line_id) REFERENCES doom.lines ON DELETE CASCADE,
    FOREIGN KEY (level_id, sector_id) REFERENCES doom.gates ON DELETE CASCADE
);

CREATE TABLE doom.ceiling_motions (
    game_id bigint NOT NULL,
    level_id bigint NOT NULL,
    sector_id integer NOT NULL,
    target_height integer NOT NULL,
    units_per_tick integer NOT NULL CHECK (units_per_tick > 0),
    PRIMARY KEY (game_id, sector_id),
    FOREIGN KEY (game_id, level_id) REFERENCES doom.games (game_id, level_id) ON DELETE CASCADE,
    FOREIGN KEY (level_id, sector_id) REFERENCES doom.sectors ON DELETE CASCADE
);
