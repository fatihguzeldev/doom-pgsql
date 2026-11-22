ALTER TABLE doom.games ADD COLUMN exit_kind text CHECK (
    exit_kind IS NULL OR (exit_kind IN ('normal', 'secret') AND finished_at_tick IS NOT NULL)
);

CREATE TABLE doom.line_actions (
    level_id bigint NOT NULL,
    line_id integer NOT NULL,
    activation text NOT NULL CHECK (activation IN ('use', 'cross', 'shoot')),
    effect text NOT NULL CHECK (effect IN ('ceiling', 'floor', 'normal', 'secret', 'teleport')),
    once_only boolean NOT NULL,
    key_kind text CHECK (key_kind IN ('blue', 'yellow', 'red')),
    units_per_tick integer NOT NULL CHECK (units_per_tick > 0),
    delay_ticks integer NOT NULL CHECK (delay_ticks >= 0),
    PRIMARY KEY (level_id, line_id),
    FOREIGN KEY (level_id, line_id) REFERENCES doom.lines ON DELETE CASCADE
);

CREATE INDEX line_actions_by_activation ON doom.line_actions (level_id, activation, line_id);

CREATE TABLE doom.line_action_targets (
    level_id bigint NOT NULL,
    line_id integer NOT NULL,
    sector_id integer NOT NULL,
    height integer NOT NULL,
    return_height integer,
    PRIMARY KEY (level_id, line_id, sector_id),
    FOREIGN KEY (level_id, line_id) REFERENCES doom.line_actions ON DELETE CASCADE,
    FOREIGN KEY (level_id, sector_id) REFERENCES doom.sectors ON DELETE CASCADE
);

CREATE TABLE doom.line_activations (
    game_id bigint NOT NULL,
    level_id bigint NOT NULL,
    line_id integer NOT NULL,
    PRIMARY KEY (game_id, line_id),
    FOREIGN KEY (game_id, level_id) REFERENCES doom.games (game_id, level_id) ON DELETE CASCADE,
    FOREIGN KEY (level_id, line_id) REFERENCES doom.line_actions ON DELETE CASCADE
);

ALTER TABLE doom.ceiling_motions
    ADD COLUMN return_height integer,
    ADD COLUMN delay_ticks integer NOT NULL DEFAULT 0 CHECK (delay_ticks >= 0),
    ADD COLUMN resume_at_tick bigint NOT NULL DEFAULT 0 CHECK (resume_at_tick >= 0);

CREATE TABLE doom.floor_motions (
    game_id bigint NOT NULL,
    level_id bigint NOT NULL,
    sector_id integer NOT NULL,
    target_height integer NOT NULL,
    units_per_tick integer NOT NULL CHECK (units_per_tick > 0),
    return_height integer,
    delay_ticks integer NOT NULL CHECK (delay_ticks >= 0),
    resume_at_tick bigint NOT NULL DEFAULT 0 CHECK (resume_at_tick >= 0),
    PRIMARY KEY (game_id, sector_id),
    FOREIGN KEY (game_id, level_id) REFERENCES doom.games (game_id, level_id) ON DELETE CASCADE,
    FOREIGN KEY (level_id, sector_id) REFERENCES doom.sectors ON DELETE CASCADE
);

CREATE TYPE doom._line_event AS (
    player doom.actors,
    exit_kind text,
    ceiling_motion boolean,
    floor_motion boolean
);
