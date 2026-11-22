CREATE TABLE doom.level_things (
    level_id bigint NOT NULL REFERENCES doom.levels ON DELETE CASCADE,
    thing_id integer NOT NULL CHECK (thing_id >= 0),
    x integer NOT NULL,
    y integer NOT NULL,
    angle_deg integer NOT NULL,
    type_code integer NOT NULL CHECK (type_code BETWEEN 0 AND 65535),
    flags integer NOT NULL CHECK (flags BETWEEN 0 AND 65535),
    PRIMARY KEY (level_id, thing_id)
);

CREATE TABLE doom.level_actor_bindings (
    level_id bigint NOT NULL REFERENCES doom.levels ON DELETE CASCADE,
    type_code integer NOT NULL CHECK (type_code BETWEEN 0 AND 65535 AND type_code <> 1),
    kind text NOT NULL REFERENCES doom.actor_types CHECK (kind <> 'player'),
    PRIMARY KEY (level_id, type_code)
);
