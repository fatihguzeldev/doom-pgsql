CREATE TABLE doom.levels (
    level_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL CHECK (name <> '')
);

CREATE TABLE doom.sectors (
    level_id bigint NOT NULL REFERENCES doom.levels ON DELETE CASCADE,
    sector_id integer NOT NULL CHECK (sector_id >= 0),
    floor_height integer NOT NULL,
    ceiling_height integer NOT NULL,
    light_level smallint NOT NULL DEFAULT 160 CHECK (light_level BETWEEN 0 AND 255),
    floor_color integer NOT NULL DEFAULT 4215976 CHECK (floor_color BETWEEN 0 AND 16777215),
    ceiling_color integer NOT NULL DEFAULT 2636864 CHECK (ceiling_color BETWEEN 0 AND 16777215),
    CHECK (floor_height <= ceiling_height),
    PRIMARY KEY (level_id, sector_id)
);

CREATE TABLE doom.lines (
    level_id bigint NOT NULL,
    line_id integer NOT NULL CHECK (line_id >= 0),
    x1 integer NOT NULL,
    y1 integer NOT NULL,
    x2 integer NOT NULL,
    y2 integer NOT NULL,
    front_sector_id integer NOT NULL,
    back_sector_id integer,
    blocking boolean NOT NULL DEFAULT false,
    wall_color integer NOT NULL DEFAULT 10052948 CHECK (wall_color BETWEEN 0 AND 16777215),
    CHECK (x1 <> x2 OR y1 <> y2),
    PRIMARY KEY (level_id, line_id),
    FOREIGN KEY (level_id, front_sector_id) REFERENCES doom.sectors ON DELETE CASCADE,
    FOREIGN KEY (level_id, back_sector_id) REFERENCES doom.sectors ON DELETE CASCADE
);

CREATE INDEX lines_front_sector ON doom.lines (level_id, front_sector_id);
CREATE INDEX lines_back_sector ON doom.lines (level_id, back_sector_id);

CREATE TABLE doom.games (
    game_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    level_id bigint NOT NULL REFERENCES doom.levels,
    tick_number bigint NOT NULL DEFAULT 0 CHECK (tick_number >= 0),
    UNIQUE (game_id, level_id)
);

CREATE TABLE doom.sector_state (
    game_id bigint NOT NULL,
    level_id bigint NOT NULL,
    sector_id integer NOT NULL,
    floor_height integer NOT NULL,
    ceiling_height integer NOT NULL,
    CHECK (floor_height <= ceiling_height),
    PRIMARY KEY (game_id, sector_id),
    FOREIGN KEY (game_id, level_id) REFERENCES doom.games (game_id, level_id) ON DELETE CASCADE,
    FOREIGN KEY (level_id, sector_id) REFERENCES doom.sectors
);

CREATE TABLE doom.actor_types (
    kind text PRIMARY KEY CHECK (kind <> ''),
    default_health integer NOT NULL CHECK (default_health > 0),
    radius double precision NOT NULL DEFAULT 16 CHECK (radius >= 0 AND radius < 'Infinity'),
    height double precision NOT NULL DEFAULT 56 CHECK (height > 0 AND height < 'Infinity'),
    color integer NOT NULL DEFAULT 13342040 CHECK (color BETWEEN 0 AND 16777215),
    blocks_actors boolean NOT NULL DEFAULT true,
    attack_range integer NOT NULL DEFAULT 0 CHECK (attack_range >= 0),
    attack_damage integer NOT NULL DEFAULT 0 CHECK (attack_damage >= 0),
    sprite_material text CHECK (sprite_material <> ''),
    dead_sprite_material text CHECK (dead_sprite_material <> ''),
    sprite_frames text[] NOT NULL DEFAULT '{}' CHECK (
        CASE WHEN coalesce(array_ndims(sprite_frames), 1) = 1 THEN
            array_position(sprite_frames, NULL) IS NULL AND array_position(sprite_frames, '') IS NULL
        ELSE false END
    ),
    dead_sprite_frames text[] NOT NULL DEFAULT '{}' CHECK (
        CASE WHEN coalesce(array_ndims(dead_sprite_frames), 1) = 1 THEN
            array_position(dead_sprite_frames, NULL) IS NULL AND array_position(dead_sprite_frames, '') IS NULL
        ELSE false END
    ),
    sprite_frame_ticks integer NOT NULL DEFAULT 1 CHECK (sprite_frame_ticks > 0),
    dead_sprite_frame_ticks integer NOT NULL DEFAULT 1 CHECK (dead_sprite_frame_ticks > 0)
);

INSERT INTO doom.actor_types (kind, default_health, attack_range, attack_damage)
VALUES ('player', 100, 512, 20);

CREATE FUNCTION doom._eye_z(p_feet_z double precision)
RETURNS double precision
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
RETURN p_feet_z + 41;

CREATE TABLE doom.actors (
    game_id bigint NOT NULL,
    actor_id bigint GENERATED ALWAYS AS IDENTITY,
    level_id bigint NOT NULL,
    sector_id integer NOT NULL,
    kind text NOT NULL REFERENCES doom.actor_types,
    x double precision NOT NULL CHECK (abs(x) < 'Infinity'),
    collision_x_bucket double precision GENERATED ALWAYS AS (floor(floor(x) / 64)) STORED,
    y double precision NOT NULL CHECK (abs(y) < 'Infinity'),
    z double precision NOT NULL CHECK (abs(z) < 'Infinity'),
    angle double precision NOT NULL DEFAULT 0 CHECK (abs(angle) < 'Infinity'),
    health integer NOT NULL,
    life_state text GENERATED ALWAYS AS (CASE WHEN health > 0 THEN 'alive' ELSE 'dead' END) STORED,
    animation_start_tick bigint NOT NULL CHECK (animation_start_tick >= 0),
    PRIMARY KEY (game_id, actor_id),
    FOREIGN KEY (game_id, level_id) REFERENCES doom.games (game_id, level_id) ON DELETE CASCADE,
    FOREIGN KEY (level_id, sector_id) REFERENCES doom.sectors
);

CREATE UNIQUE INDEX actors_one_player_per_game ON doom.actors (game_id) WHERE kind = 'player';
CREATE INDEX actors_in_sector ON doom.actors (game_id, sector_id);
-- Movement within a bucket can still use a heap-only update.
CREATE INDEX actors_collision_x_bucket ON doom.actors (game_id, collision_x_bucket);

CREATE FUNCTION doom.sector_at(p_level_id bigint, p_x double precision, p_y double precision)
RETURNS integer
LANGUAGE sql STABLE STRICT PARALLEL SAFE
RETURN (
    SELECT side.sector_id
    FROM doom.lines AS line
    CROSS JOIN LATERAL (VALUES (line.front_sector_id), (line.back_sector_id)) AS side(sector_id)
    WHERE line.level_id = p_level_id
      AND side.sector_id IS NOT NULL
      AND CASE WHEN (line.y1 > p_y) <> (line.y2 > p_y) THEN
            p_x < line.x1 + (p_y - line.y1) * (line.x2::double precision - line.x1)
                    / (line.y2::double precision - line.y1)
          ELSE false END
    GROUP BY side.sector_id
    HAVING count(*) % 2 = 1
    ORDER BY side.sector_id
    LIMIT 1
);

CREATE FUNCTION doom.prepare_actor_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    SELECT level_id, tick_number INTO NEW.level_id, NEW.animation_start_tick
    FROM doom.games WHERE game_id = NEW.game_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'game % does not exist', NEW.game_id USING ERRCODE = '23503';
    END IF;

    IF NEW.sector_id IS NULL THEN
        NEW.sector_id := doom.sector_at(NEW.level_id, NEW.x, NEW.y);
        IF NEW.sector_id IS NULL THEN
            RAISE EXCEPTION 'spawn at (%, %) is outside level %', NEW.x, NEW.y, NEW.level_id
                USING ERRCODE = '23514';
        END IF;
    END IF;

    IF NEW.z IS NULL THEN
        SELECT coalesce(state.floor_height, sector.floor_height) INTO NEW.z
        FROM doom.sectors AS sector
        LEFT JOIN doom.sector_state AS state
            ON state.game_id = NEW.game_id AND state.sector_id = sector.sector_id
        WHERE sector.level_id = NEW.level_id AND sector.sector_id = NEW.sector_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'sector % does not exist in level %', NEW.sector_id, NEW.level_id
                USING ERRCODE = '23503';
        END IF;
    END IF;

    IF NEW.health IS NULL THEN
        SELECT default_health INTO NEW.health FROM doom.actor_types WHERE kind = NEW.kind;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'actor type % does not exist', NEW.kind USING ERRCODE = '23503';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER actors_prepare_insert
BEFORE INSERT ON doom.actors
FOR EACH ROW EXECUTE FUNCTION doom.prepare_actor_insert();

CREATE FUNCTION doom.restart_actor_animation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    -- A plain read avoids locking the game after the actor during a health edit.
    SELECT tick_number INTO NEW.animation_start_tick FROM doom.games WHERE game_id = NEW.game_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'game % does not exist', NEW.game_id USING ERRCODE = '23503';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER actors_restart_animation
BEFORE UPDATE OF health ON doom.actors
FOR EACH ROW WHEN ((OLD.health > 0) <> (NEW.health > 0))
EXECUTE FUNCTION doom.restart_actor_animation();

CREATE FUNCTION doom.carry_floor_actors(p_game_id bigint, p_sector_id integer, p_from integer, p_to integer)
RETURNS void
LANGUAGE sql
BEGIN ATOMIC
    UPDATE doom.actors SET z = p_to
    WHERE game_id = p_game_id AND sector_id = p_sector_id AND z = p_from AND p_from <> p_to;
END;

CREATE FUNCTION doom.apply_sector_floor()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    base_height integer;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF (OLD.game_id, OLD.level_id, OLD.sector_id) = (NEW.game_id, NEW.level_id, NEW.sector_id) THEN
            IF OLD.floor_height <> NEW.floor_height THEN
                PERFORM doom.carry_floor_actors(NEW.game_id, NEW.sector_id, OLD.floor_height, NEW.floor_height);
            END IF;
            RETURN NULL;
        END IF;
    END IF;

    IF TG_OP <> 'INSERT' THEN
        SELECT floor_height INTO base_height FROM doom.sectors
        WHERE level_id = OLD.level_id AND sector_id = OLD.sector_id;
        PERFORM doom.carry_floor_actors(OLD.game_id, OLD.sector_id, OLD.floor_height, base_height);
    END IF;

    IF TG_OP <> 'DELETE' THEN
        SELECT floor_height INTO base_height FROM doom.sectors
        WHERE level_id = NEW.level_id AND sector_id = NEW.sector_id;
        PERFORM doom.carry_floor_actors(NEW.game_id, NEW.sector_id, base_height, NEW.floor_height);
    END IF;

    RETURN NULL;
END;
$$;

CREATE TRIGGER sector_state_apply_floor
AFTER INSERT OR UPDATE OR DELETE ON doom.sector_state
FOR EACH ROW EXECUTE FUNCTION doom.apply_sector_floor();
