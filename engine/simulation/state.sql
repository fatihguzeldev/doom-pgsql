CREATE TYPE doom._sim_input AS (
    forward double precision, strafe double precision, turn double precision,
    use_pressed boolean, fire_pressed boolean
);

CREATE TABLE doom.games (
    game_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    level_id bigint NOT NULL REFERENCES doom.levels,
    epoch bigint NOT NULL CHECK (epoch > 0),
    tick_number bigint NOT NULL DEFAULT 0 CHECK (tick_number >= 0),
    skill integer NOT NULL CHECK (skill BETWEEN 1 AND 5),
    finished_at_tick bigint,
    exit_kind text CHECK (exit_kind IN ('normal', 'secret')),
    last_input doom._sim_input,
    next_attack bigint NOT NULL DEFAULT 0 CHECK (next_attack >= 0),
    has_cross_actions boolean NOT NULL DEFAULT false,
    UNIQUE (game_id, level_id),
    CHECK ((finished_at_tick IS NULL AND exit_kind IS NULL)
        OR (finished_at_tick = tick_number AND exit_kind IS NOT NULL))
);

CREATE TABLE doom.sector_state (
    game_id bigint NOT NULL,
    level_id bigint NOT NULL,
    sector_id integer NOT NULL,
    floor_height integer NOT NULL,
    ceiling_height integer NOT NULL,
    PRIMARY KEY (game_id, sector_id),
    FOREIGN KEY (game_id, level_id) REFERENCES doom.games (game_id, level_id) ON DELETE CASCADE,
    FOREIGN KEY (level_id, sector_id) REFERENCES doom.sectors,
    CHECK (floor_height <= ceiling_height)
);

CREATE TABLE doom.thing_types (
    type_id integer PRIMARY KEY,
    kind text NOT NULL CHECK (kind IN ('player', 'monster', 'pickup', 'prop')),
    health integer NOT NULL DEFAULT 1 CHECK (health > 0),
    height integer NOT NULL DEFAULT 16 CHECK (height > 0),
    radius integer NOT NULL DEFAULT 12 CHECK (radius BETWEEN 1 AND 32),
    blocks_actors boolean NOT NULL DEFAULT false,
    shootable boolean NOT NULL DEFAULT false,
    move_speed integer NOT NULL DEFAULT 0 CHECK (move_speed >= 0),
    attack_range integer NOT NULL DEFAULT 0 CHECK (attack_range >= 0),
    attack_damage integer NOT NULL DEFAULT 0 CHECK (attack_damage >= 0),
    item text,
    amount integer CHECK (amount > 0),
    sprite text,
    corpse text,
    CHECK ((kind = 'pickup') = (item IS NOT NULL AND amount IS NOT NULL))
);

CREATE TABLE doom.actors (
    game_id bigint NOT NULL,
    actor_id bigint GENERATED ALWAYS AS IDENTITY,
    level_id bigint NOT NULL,
    sector_id integer NOT NULL,
    type_id integer NOT NULL REFERENCES doom.thing_types,
    kind text NOT NULL CHECK (kind IN ('player', 'monster', 'pickup', 'prop')),
    x double precision NOT NULL CHECK (abs(x) <= 1000000),
    cell_x integer GENERATED ALWAYS AS (floor(x / 64)::integer) STORED,
    y double precision NOT NULL CHECK (abs(y) <= 1000000),
    z double precision NOT NULL CHECK (abs(z) <= 1000000),
    angle double precision NOT NULL CHECK (abs(angle) <= 10),
    health integer NOT NULL CHECK (health BETWEEN 0 AND 1000000),
    life_state text GENERATED ALWAYS AS (CASE WHEN health > 0 THEN 'alive' ELSE 'dead' END) STORED,
    animation_start_tick bigint NOT NULL DEFAULT 0 CHECK (animation_start_tick >= 0),
    sprite_material text,
    think_slot integer NOT NULL DEFAULT 0 CHECK (think_slot BETWEEN 0 AND 7),
    next_think bigint NOT NULL DEFAULT 0 CHECK (next_think >= 0),
    PRIMARY KEY (game_id, actor_id),
    FOREIGN KEY (game_id, level_id) REFERENCES doom.games (game_id, level_id) ON DELETE CASCADE,
    FOREIGN KEY (level_id, sector_id) REFERENCES doom.sectors
) WITH (fillfactor = 85);

CREATE UNIQUE INDEX actors_player ON doom.actors (game_id) WHERE kind = 'player';
CREATE INDEX actors_in_sector ON doom.actors (game_id, sector_id);
CREATE INDEX actors_live_monsters ON doom.actors (game_id, think_slot, actor_id)
    WHERE kind = 'monster' AND life_state = 'alive';
-- x edits within one cell leave the indexed key unchanged.
CREATE INDEX actors_live_cells ON doom.actors (game_id, cell_x) WHERE life_state = 'alive';

CREATE TABLE doom.game_inventory (
    game_id bigint NOT NULL REFERENCES doom.games ON DELETE CASCADE,
    item text NOT NULL,
    amount integer NOT NULL CHECK (amount BETWEEN 1 AND 1000000),
    PRIMARY KEY (game_id, item)
);

INSERT INTO doom.thing_types (type_id, kind, health, height, radius, blocks_actors, shootable,
    move_speed, attack_range, attack_damage, sprite, corpse)
VALUES
    (1, 'player', 100, 56, 16, true, true, 0, 512, 20, NULL, 'PLAYN0'),
    (9, 'monster', 30, 56, 20, true, true, 4, 128, 8, 'SPOSA1', 'SPOSL0'),
    (58, 'monster', 150, 56, 30, true, true, 8, 40, 10, 'SARGA1', 'SARGN0'),
    (3001, 'monster', 60, 56, 20, true, true, 5, 96, 6, 'TROOA1', 'TROOM0'),
    (3002, 'monster', 150, 56, 30, true, true, 8, 40, 10, 'SARGA1', 'SARGN0'),
    (3003, 'monster', 500, 64, 24, true, true, 5, 224, 12, 'BOSSA1', 'BOSSO0'),
    (3004, 'monster', 20, 56, 20, true, true, 4, 192, 4, 'POSSA1', 'POSSL0'),
    (3005, 'monster', 400, 56, 31, true, true, 5, 96, 6, 'HEADA1', 'HEADL0'),
    (3006, 'monster', 100, 56, 16, true, true, 6, 96, 6, 'SKULA1', 'SKULF0'),
    (2035, 'prop', 20, 32, 10, true, true, 0, 0, 0, 'BAR1A0', NULL);

INSERT INTO doom.thing_types (type_id, kind, blocks_actors, sprite)
VALUES
    (10, 'prop', false, 'PLAYW0'), (12, 'prop', false, 'PLAYW0'),
    (15, 'prop', false, 'PLAYN0'), (18, 'prop', false, 'POSSL0'),
    (19, 'prop', false, 'SPOSL0'), (20, 'prop', false, 'TROOM0'),
    (21, 'prop', false, 'SARGN0'), (22, 'prop', false, 'HEADL0'),
    (24, 'prop', false, 'POL5A0'), (34, 'prop', false, 'CANDA0'),
    (35, 'prop', true, 'CBRAA0'), (44, 'prop', true, 'TBLUA0'),
    (45, 'prop', true, 'TGRNA0'), (46, 'prop', true, 'TREDA0'),
    (48, 'prop', true, 'ELECA0'), (2028, 'prop', true, 'COLUA0');

INSERT INTO doom.thing_types (type_id, kind, item, amount, sprite)
VALUES
    (5, 'pickup', 'key-blue', 1, 'BKEYA0'), (6, 'pickup', 'key-yellow', 1, 'YKEYA0'),
    (13, 'pickup', 'key-red', 1, 'RKEYA0'), (38, 'pickup', 'key-red', 1, 'RSKUB0'),
    (39, 'pickup', 'key-yellow', 1, 'YSKUB0'), (40, 'pickup', 'key-blue', 1, 'BSKUB0'),
    (8, 'pickup', 'bullets', 20, 'BPAKA0'),
    (17, 'pickup', 'energy', 100, 'CELPA0'),
    (2001, 'pickup', 'shotgun', 1, 'SHOTA0'), (2002, 'pickup', 'chaingun', 1, 'MGUNA0'),
    (2003, 'pickup', 'launcher', 1, 'LAUNA0'), (2004, 'pickup', 'plasma', 1, 'PLASA0'),
    (2005, 'pickup', 'chainsaw', 1, 'CSAWA0'), (2006, 'pickup', 'burst', 1, 'BFUGA0'),
    (2007, 'pickup', 'bullets', 10, 'CLIPA0'), (2008, 'pickup', 'shells', 4, 'SHELA0'),
    (2010, 'pickup', 'rockets', 1, 'ROCKA0'), (2011, 'pickup', 'health', 10, 'STIMA0'),
    (2012, 'pickup', 'health', 25, 'MEDIA0'), (2013, 'pickup', 'health-bonus', 100, 'SOULA0'),
    (2014, 'pickup', 'health-bonus', 1, 'BON1A0'), (2015, 'pickup', 'armor-bonus', 1, 'BON2A0'),
    (2018, 'pickup', 'armor', 100, 'ARM1A0'), (2019, 'pickup', 'armor', 200, 'ARM2A0'),
    (2022, 'pickup', 'shield', 1, 'PINVA0'), (2023, 'pickup', 'surge', 1, 'PSTRA0'),
    (2024, 'pickup', 'concealment', 1, 'PINSA0'), (2025, 'pickup', 'hazard-protection', 1, 'SUITA0'),
    (2026, 'pickup', 'scanner', 1, 'PMAPA0'), (2045, 'pickup', 'light-amplification', 1, 'PVISA0'),
    (2046, 'pickup', 'rockets', 5, 'BROKA0'), (2047, 'pickup', 'energy', 20, 'CELLA0'),
    (2048, 'pickup', 'bullets', 50, 'AMMOA0'), (2049, 'pickup', 'shells', 20, 'SBOXA0');
