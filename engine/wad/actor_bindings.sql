CREATE TABLE doom.wad_actor_types (
    type_code integer PRIMARY KEY CHECK (type_code BETWEEN 0 AND 65535 AND type_code <> 1),
    kind text NOT NULL UNIQUE REFERENCES doom.actor_types
);

ALTER TABLE doom.level_actor_bindings ADD COLUMN use_wad_flags boolean NOT NULL DEFAULT false;

CREATE TABLE doom.wad_item_pickups (
    kind text PRIMARY KEY REFERENCES doom.actor_types ON DELETE CASCADE,
    item_kind text NOT NULL CHECK (item_kind <> ''),
    amount integer NOT NULL CHECK (amount > 0)
);

CREATE TABLE doom.game_keys (
    game_id bigint NOT NULL REFERENCES doom.games ON DELETE CASCADE,
    key_kind text NOT NULL CHECK (key_kind IN ('blue', 'red', 'yellow')),
    PRIMARY KEY (game_id, key_kind)
);

CREATE TABLE doom.game_inventory (
    game_id bigint NOT NULL REFERENCES doom.games ON DELETE CASCADE,
    item_kind text NOT NULL CHECK (item_kind <> ''),
    amount integer NOT NULL CHECK (amount > 0),
    PRIMARY KEY (game_id, item_kind)
);

-- The classic format only stores editor codes. These bindings select generic behaviors and archive sprite names.
WITH definitions (type_code, behavior, sprite, dead_sprite, item, amount) AS (
    VALUES
        (5, 'item', 'BKEYA0', NULL, 'key-blue', 1),
        (6, 'item', 'YKEYA0', NULL, 'key-yellow', 1),
        (7, 'heavy', 'SPIDG1', 'SPIDL0', NULL, 0),
        (8, 'item', 'BPAKA0', NULL, 'supply-pack', 1),
        (9, 'shooter', 'SPOSA1', 'SPOSL0', NULL, 0),
        (10, 'detail', 'PLAYW0', NULL, NULL, 0),
        (12, 'detail', 'PLAYW0', NULL, NULL, 0),
        (13, 'item', 'RKEYA0', NULL, 'key-red', 1),
        (15, 'detail', 'PLAYN0', NULL, NULL, 0),
        (16, 'heavy', 'CYBRA1', 'CYBRP0', NULL, 0),
        (17, 'item', 'CELPA0', NULL, 'energy', 24),
        (18, 'detail', 'POSSL0', NULL, NULL, 0),
        (19, 'detail', 'SPOSL0', NULL, NULL, 0),
        (20, 'detail', 'TROOM0', NULL, NULL, 0),
        (21, 'detail', 'SARGN0', NULL, NULL, 0),
        (22, 'detail', 'HEADL0', NULL, NULL, 0),
        (24, 'detail', 'POL5A0', NULL, NULL, 0),
        (34, 'detail', 'CANDA0', NULL, NULL, 0),
        (35, 'obstacle', 'CBRAA0', NULL, NULL, 0),
        (38, 'item', 'RSKUB0', NULL, 'key-red', 1),
        (39, 'item', 'YSKUB0', NULL, 'key-yellow', 1),
        (40, 'item', 'BSKUB0', NULL, 'key-blue', 1),
        (44, 'obstacle', 'TBLUA0', NULL, NULL, 0),
        (45, 'obstacle', 'TGRNA0', NULL, NULL, 0),
        (46, 'obstacle', 'TREDA0', NULL, NULL, 0),
        (48, 'obstacle', 'ELECA0', NULL, NULL, 0),
        (58, 'brawler', 'SARGA1', 'SARGN0', NULL, 0),
        (2001, 'item', 'SHOTA0', NULL, 'weapon-spread', 1),
        (2002, 'item', 'MGUNA0', NULL, 'weapon-rapid', 1),
        (2003, 'item', 'LAUNA0', NULL, 'weapon-heavy', 1),
        (2004, 'item', 'PLASA0', NULL, 'weapon-energy', 1),
        (2005, 'item', 'CSAWA0', NULL, 'weapon-melee', 1),
        (2006, 'item', 'BFUGA0', NULL, 'weapon-burst', 1),
        (2007, 'item', 'CLIPA0', NULL, 'rounds', 8),
        (2008, 'item', 'SHELA0', NULL, 'shells', 4),
        (2010, 'item', 'ROCKA0', NULL, 'rockets', 1),
        (2011, 'health', 'STIMA0', NULL, NULL, 10),
        (2012, 'health', 'MEDIA0', NULL, NULL, 25),
        (2013, 'health', 'SOULA0', NULL, NULL, 75),
        (2014, 'health', 'BON1A0', NULL, NULL, 2),
        (2015, 'item', 'BON2A0', NULL, 'armor', 2),
        (2018, 'item', 'ARM1A0', NULL, 'armor', 40),
        (2019, 'item', 'ARM2A0', NULL, 'armor', 65),
        (2022, 'item', 'PINVA0', NULL, 'shield', 1),
        (2023, 'item', 'PSTRA0', NULL, 'surge', 1),
        (2024, 'item', 'PINSA0', NULL, 'concealment', 1),
        (2025, 'item', 'SUITA0', NULL, 'hazard-protection', 1),
        (2026, 'item', 'PMAPA0', NULL, 'scanner', 1),
        (2028, 'obstacle', 'COLUA0', NULL, NULL, 0),
        (2035, 'breakable', 'BAR1A0', NULL, NULL, 20),
        (2045, 'item', 'PVISA0', NULL, 'light-amplification', 1),
        (2046, 'item', 'BROKA0', NULL, 'rockets', 5),
        (2047, 'item', 'CELLA0', NULL, 'energy', 8),
        (2048, 'item', 'AMMOA0', NULL, 'rounds', 32),
        (2049, 'item', 'SBOXA0', NULL, 'shells', 16),
        (3001, 'striker', 'TROOA1', 'TROOM0', NULL, 0),
        (3002, 'brawler', 'SARGA1', 'SARGN0', NULL, 0),
        (3003, 'heavy', 'BOSSA1', 'BOSSO0', NULL, 0),
        (3004, 'guard', 'POSSA1', 'POSSL0', NULL, 0),
        (3005, 'striker', 'HEADA1', 'HEADL0', NULL, 0),
        (3006, 'striker', 'SKULA1', 'SKULF0', NULL, 0)
), actor_definitions AS (
    SELECT *, 'wad thing ' || type_code AS kind,
           behavior IN ('guard', 'shooter', 'striker', 'brawler', 'heavy') AS hostile
    FROM definitions
), registered_types AS (
    INSERT INTO doom.actor_types (kind, default_health, radius, height, color, blocks_actors,
                                  shootable, attack_range, attack_damage, sprite_material, dead_sprite_material)
    SELECT kind,
           CASE behavior WHEN 'guard' THEN 20 WHEN 'shooter' THEN 35 WHEN 'striker' THEN 45
               WHEN 'brawler' THEN 60 WHEN 'heavy' THEN 180 WHEN 'breakable' THEN 20 ELSE 1 END,
           CASE WHEN behavior = 'heavy' THEN 22 WHEN hostile THEN 15
                WHEN behavior IN ('obstacle', 'breakable') THEN 10 WHEN behavior = 'item' THEN 20 ELSE 6 END,
           CASE WHEN behavior = 'heavy' THEN 64 WHEN hostile THEN 56
                WHEN behavior = 'obstacle' THEN 48 WHEN behavior = 'breakable' THEN 32 ELSE 12 END,
           CASE WHEN hostile THEN 11425872 WHEN behavior = 'health' THEN 5610218
                WHEN behavior = 'item' THEN 14273358 ELSE 9797744 END,
           hostile OR behavior IN ('obstacle', 'breakable'), hostile OR behavior = 'breakable',
           CASE behavior WHEN 'guard' THEN 192 WHEN 'shooter' THEN 128 WHEN 'striker' THEN 96
               WHEN 'brawler' THEN 40 WHEN 'heavy' THEN 224 ELSE 0 END,
           CASE behavior WHEN 'guard' THEN 4 WHEN 'shooter' THEN 8 WHEN 'striker' THEN 6
               WHEN 'brawler' THEN 10 WHEN 'heavy' THEN 12 ELSE 0 END,
           sprite, dead_sprite
    FROM actor_definitions
    RETURNING kind
), registered_pursuits AS (
    INSERT INTO doom.actor_pursuits (kind, sight_range, move_distance, interval_ticks)
    SELECT actor.kind, 320, CASE WHEN actor.behavior = 'heavy' THEN 14 ELSE 20 END, 21
    FROM actor_definitions AS actor JOIN registered_types USING (kind)
    WHERE actor.hostile
), registered_health AS (
    INSERT INTO doom.health_pickups (kind, amount)
    SELECT actor.kind, actor.amount FROM actor_definitions AS actor JOIN registered_types USING (kind)
    WHERE actor.behavior = 'health'
), registered_items AS (
    INSERT INTO doom.wad_item_pickups (kind, item_kind, amount)
    SELECT actor.kind, actor.item, actor.amount FROM actor_definitions AS actor JOIN registered_types USING (kind)
    WHERE actor.behavior = 'item'
)
INSERT INTO doom.wad_actor_types (type_code, kind)
SELECT actor.type_code, actor.kind FROM actor_definitions AS actor JOIN registered_types USING (kind);

CREATE FUNCTION doom._wad_thing_enabled(p_flags integer, p_skill integer)
RETURNS boolean
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
RETURN (p_flags & 16) = 0 AND (p_flags & CASE
    WHEN p_skill IN (1, 2) THEN 1 WHEN p_skill = 3 THEN 2 WHEN p_skill IN (4, 5) THEN 4 ELSE 0
END) <> 0;

CREATE FUNCTION doom.wad_unbound_things(p_level_id bigint, p_skill integer DEFAULT 3)
RETURNS TABLE (type_code integer, thing_count bigint)
LANGUAGE sql STABLE STRICT PARALLEL SAFE
BEGIN ATOMIC
    SELECT thing.type_code, count(*)
    FROM doom.level_things AS thing
    LEFT JOIN doom.level_actor_bindings AS binding USING (level_id, type_code)
    WHERE thing.level_id = p_level_id AND binding.kind IS NULL
      AND thing.type_code NOT IN (1, 2, 3, 4, 11, 14)
      AND doom._wad_thing_enabled(thing.flags, p_skill)
    GROUP BY thing.type_code
    ORDER BY thing.type_code;
END;

CREATE FUNCTION doom._bind_wad_actors(p_level_id bigint, p_wad bytea)
RETURNS void
LANGUAGE plpgsql STRICT
AS $$
DECLARE
    sprites text[];
BEGIN
    PERFORM 1 FROM doom.levels WHERE level_id = p_level_id FOR NO KEY UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'level % does not exist', p_level_id USING ERRCODE = '22023';
    END IF;

    INSERT INTO doom.level_actor_bindings (level_id, type_code, kind, use_wad_flags)
    SELECT DISTINCT p_level_id, thing.type_code, catalog.kind, true
    FROM doom.level_things AS thing
    JOIN doom.wad_actor_types AS catalog USING (type_code)
    WHERE thing.level_id = p_level_id
    ON CONFLICT (level_id, type_code) DO NOTHING;

    -- Resolve only selected sprite references so minimal archives can use the solid actor fallback.
    SELECT array_agg(sprite.name ORDER BY sprite.name) INTO sprites
    FROM (
        SELECT DISTINCT name FROM (
            SELECT actor.sprite_material AS name
            FROM doom.level_actor_bindings AS binding JOIN doom.actor_types AS actor USING (kind)
            WHERE binding.level_id = p_level_id AND binding.use_wad_flags
            UNION ALL
            SELECT actor.dead_sprite_material
            FROM doom.level_actor_bindings AS binding JOIN doom.actor_types AS actor USING (kind)
            WHERE binding.level_id = p_level_id AND binding.use_wad_flags
        ) AS requested
        WHERE name IS NOT NULL
    ) AS sprite
    WHERE EXISTS (SELECT FROM doom.wad_directory(p_wad) AS lump
                  WHERE lump.data_size > 0 AND upper(lump.name COLLATE "C") = sprite.name);
    IF sprites IS NOT NULL THEN
        PERFORM doom.import_wad_sprites(p_level_id, p_wad, sprites);
    END IF;
END;
$$;

CREATE FUNCTION doom._collect_wad_items(p_player doom.actors, p_height double precision, p_radius double precision)
RETURNS void
LANGUAGE plpgsql STRICT
AS $$
DECLARE
    pickup record;
BEGIN
    FOR pickup IN
        SELECT candidate.actor_id, candidate.sector_id, candidate.x, candidate.y, candidate.z,
               item.item_kind, item.amount
        FROM doom.wad_item_pickups AS item
        JOIN doom.actor_types AS kind USING (kind)
        CROSS JOIN LATERAL (SELECT p_radius + kind.radius AS reach) AS contact
        CROSS JOIN LATERAL (
            SELECT actor.actor_id, actor.sector_id, actor.x, actor.y, actor.z
            FROM doom.actors AS actor
            WHERE actor.game_id = p_player.game_id AND actor.kind = item.kind AND actor.life_state = 'alive'
              AND actor.collision_x_bucket BETWEEN floor(floor(p_player.x - contact.reach) / 64)
                AND floor(floor(p_player.x + contact.reach) / 64)
              AND actor.x BETWEEN p_player.x - contact.reach AND p_player.x + contact.reach
              AND actor.y BETWEEN p_player.y - contact.reach AND p_player.y + contact.reach
              AND actor.z < p_player.z + p_height AND actor.z + kind.height > p_player.z
              AND (point(actor.x, actor.y) <-> point(p_player.x, p_player.y)) <= contact.reach
            FOR UPDATE OF actor SKIP LOCKED
        ) AS candidate
        ORDER BY candidate.actor_id
    LOOP
        -- A hand can reach across an open lip that a standing actor cannot climb.
        IF (pickup.sector_id = p_player.sector_id AND abs(pickup.x - p_player.x) < 0.00000001
                                               AND abs(pickup.y - p_player.y) < 0.00000001)
            OR EXISTS (
                SELECT FROM doom._ray_sectors(p_player, pickup.x - p_player.x, pickup.y - p_player.y,
                                              greatest(p_player.z, pickup.z)) AS path
                WHERE path.sector_id = pickup.sector_id AND path.end_t = 1 AND NOT path.end_blocked
            ) THEN
            DELETE FROM doom.actors WHERE game_id = p_player.game_id AND actor_id = pickup.actor_id;
            IF FOUND THEN
                IF pickup.item_kind IN ('key-blue', 'key-red', 'key-yellow') THEN
                    INSERT INTO doom.game_keys (game_id, key_kind)
                    VALUES (p_player.game_id, substring(pickup.item_kind FROM 5))
                    ON CONFLICT (game_id, key_kind) DO NOTHING;
                ELSE
                    INSERT INTO doom.game_inventory AS held (game_id, item_kind, amount)
                    VALUES (p_player.game_id, pickup.item_kind, pickup.amount)
                    ON CONFLICT (game_id, item_kind) DO UPDATE
                    SET amount = least(2147483647, held.amount::bigint + EXCLUDED.amount);
                END IF;
            END IF;
        END IF;
    END LOOP;
END;
$$;
