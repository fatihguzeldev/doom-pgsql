CREATE TYPE doom._shot_contact AS (
    actor_id bigint,
    distance double precision
);

CREATE FUNCTION doom._ray_hit(
    p_actor doom.actors, p_range double precision, p_z double precision
)
RETURNS doom._shot_contact
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    roundoff constant double precision := 8.881784197001252e-16;
    axis_slop constant double precision := 0.00000001;
    ray_x double precision := cos(p_actor.angle);
    ray_y double precision := sin(p_actor.angle);
    ray_dx double precision;
    ray_dy double precision;
    ray_length double precision := p_range;
    axis_cutoff double precision;
BEGIN
    IF p_actor IS NULL OR p_range IS NULL OR p_z IS NULL
        OR p_range < axis_slop OR p_range >= 'Infinity' OR abs(p_z) >= 'Infinity'
    THEN
        RETURN NULL;
    END IF;

    -- Use the same snapped axes as the sector trace, including for subnormal direction components.
    axis_cutoff := axis_slop / p_range;
    ray_dx := CASE WHEN abs(ray_x) >= axis_cutoff THEN p_range * ray_x ELSE 0 END;
    ray_dy := CASE WHEN abs(ray_y) >= axis_cutoff THEN p_range * ray_y ELSE 0 END;
    IF least(abs(ray_dx), abs(ray_dy)) < axis_slop THEN
        ray_dx := CASE WHEN abs(ray_dx) < axis_slop THEN 0 ELSE ray_dx END;
        ray_dy := CASE WHEN abs(ray_dy) < axis_slop THEN 0 ELSE ray_dy END;
        ray_x := sign(ray_dx);
        ray_y := sign(ray_dy);
        ray_length := greatest(abs(ray_dx), abs(ray_dy));
    END IF;

    RETURN (
    WITH path AS (
        SELECT span.*,
               max(span.end_t) FILTER (WHERE span.end_blocked) OVER () AS blocked_t
        FROM doom._ray_sectors(p_actor, ray_dx, ray_dy, p_z) AS span
    )
    SELECT ROW(target.actor_id, target.distance)::doom._shot_contact
    FROM path
    CROSS JOIN LATERAL (
        SELECT body.actor_id, contact.distance
        FROM doom.actors AS body
        JOIN doom.thing_types AS kind ON kind.type_id = body.type_id
        CROSS JOIN LATERAL (
            SELECT body.x - p_actor.x AS x, body.y - p_actor.y AS y
        ) AS relative
        CROSS JOIN LATERAL (
            SELECT relative.x * ray_x + relative.y * ray_y AS along,
                   abs(relative.x * ray_y - relative.y * ray_x) AS across
        ) AS projected
        CROSS JOIN LATERAL (
            SELECT CASE WHEN projected.across <= kind.radius
                THEN sqrt((kind.radius - projected.across) * (kind.radius + projected.across))
            END AS half_chord
        ) AS cylinder
        CROSS JOIN LATERAL (
            SELECT greatest(path.start_t * ray_length, projected.along - cylinder.half_chord) AS distance,
                   roundoff * greatest(ray_length, abs(projected.along), cylinder.half_chord) AS error_margin
        ) AS contact
        WHERE body.game_id = p_actor.game_id AND body.sector_id = path.sector_id
          AND body.health > 0 AND kind.shootable AND body.actor_id <> p_actor.actor_id
          AND body.z <= p_z AND p_z - body.z < kind.height
          AND relative.x BETWEEN least(ray_dx * path.start_t, ray_dx * path.end_t) - kind.radius
                             AND greatest(ray_dx * path.start_t, ray_dx * path.end_t) + kind.radius
          AND relative.y BETWEEN least(ray_dy * path.start_t, ray_dy * path.end_t) - kind.radius
                             AND greatest(ray_dy * path.start_t, ray_dy * path.end_t) + kind.radius
          AND projected.along + cylinder.half_chord >= path.start_t * ray_length - contact.error_margin
          AND contact.distance - path.end_t * ray_length <= contact.error_margin
          -- A distance rounded just inside the wall still belongs to the blocked endpoint.
          AND (path.blocked_t IS NULL OR path.blocked_t * ray_length - contact.distance > contact.error_margin)
        ORDER BY contact.distance, body.actor_id
        LIMIT 1
    ) AS target
    WHERE path.start_t < path.end_t
    ORDER BY target.distance, target.actor_id
    LIMIT 1
    );
END;
$$;

CREATE FUNCTION doom._spend_inventory(p_game bigint, p_item text, p_amount integer)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    available integer;
    spent integer;
BEGIN
    SELECT amount INTO available FROM doom.game_inventory WHERE game_id = p_game AND item = p_item FOR UPDATE;
    IF NOT FOUND THEN
        RETURN 0;
    END IF;
    spent := least(available, p_amount);
    IF spent = available THEN
        DELETE FROM doom.game_inventory WHERE game_id = p_game AND item = p_item;
    ELSE
        UPDATE doom.game_inventory SET amount = available - spent WHERE game_id = p_game AND item = p_item;
    END IF;
    RETURN spent;
END;
$$;

CREATE FUNCTION doom._hurt(p_game bigint, p_actor bigint, p_damage integer, p_tic bigint)
RETURNS void
LANGUAGE sql
BEGIN ATOMIC
    UPDATE doom.actors AS actor
    SET health = greatest(0, actor.health - p_damage),
        animation_start_tick = CASE WHEN actor.health <= p_damage THEN p_tic ELSE actor.animation_start_tick END,
        sprite_material = CASE WHEN actor.health <= p_damage THEN kind.corpse ELSE actor.sprite_material END
    FROM doom.thing_types AS kind
    WHERE actor.game_id = p_game AND actor.actor_id = p_actor AND actor.health > 0
      AND kind.type_id = actor.type_id;
END;

CREATE FUNCTION doom._player_shot(p_actor doom.actors, p_tic bigint)
RETURNS double precision
LANGUAGE plpgsql
AS $$
DECLARE
    reach integer := 48;
    damage integer := 10;
    weapon record;
    hit doom._shot_contact;
    lower_hit doom._shot_contact;
BEGIN
    SELECT candidate.reach, candidate.damage, candidate.ammo
    INTO weapon
    FROM (VALUES (1, 'burst',    'energy',  512, 60),
                 (2, 'plasma',   'energy',  512, 30),
                 (3, 'launcher', 'rockets', 512, 45),
                 (4, 'chaingun', 'bullets', 512, 25),
                 (5, 'shotgun',  'shells',  384, 40),
                 (6, NULL,       'bullets', 512, 20)) AS candidate(pos, item, ammo, reach, damage)
    JOIN doom.game_inventory AS supply ON supply.game_id = p_actor.game_id AND supply.item = candidate.ammo
    WHERE candidate.item IS NULL OR EXISTS (
        SELECT FROM doom.game_inventory AS held WHERE held.game_id = p_actor.game_id AND held.item = candidate.item
    )
    ORDER BY candidate.pos LIMIT 1;
    IF FOUND AND doom._spend_inventory(p_actor.game_id, weapon.ammo, 1) = 1 THEN
        reach := weapon.reach;
        damage := weapon.damage;
    END IF;

    hit := doom._ray_hit(p_actor, reach, doom._eye_z(p_actor.z));
    IF hit.actor_id IS NULL THEN
        lower_hit := doom._ray_hit(p_actor, least(reach, 128), p_actor.z + 24);
        IF lower_hit.actor_id IS NOT NULL AND lower_hit.distance > 0 AND EXISTS (
            SELECT FROM doom._ray_sectors(p_actor, lower_hit.distance * cos(p_actor.angle),
                lower_hit.distance * sin(p_actor.angle), doom._eye_z(p_actor.z)) AS path
            WHERE path.end_t = 1 AND NOT path.end_blocked
        ) THEN
            hit := lower_hit;
        END IF;
    END IF;
    IF hit.actor_id IS NOT NULL THEN
        PERFORM doom._hurt(p_actor.game_id, hit.actor_id, damage, p_tic);
    END IF;
    RETURN coalesce(hit.distance, reach);
END;
$$;

CREATE FUNCTION doom._collect_items(p_player doom.actors, p_height integer, p_radius integer)
RETURNS doom.actors
LANGUAGE plpgsql
AS $$
DECLARE
    pickup record;
    reach integer := p_radius + 32;
BEGIN
    FOR pickup IN
        SELECT actor.actor_id, actor.x, actor.y, actor.z, actor.sector_id, kind.item, kind.amount
        FROM doom.actors AS actor
        JOIN doom.thing_types AS kind USING (type_id)
        WHERE actor.game_id = p_player.game_id AND actor.kind = 'pickup' AND actor.life_state = 'alive'
          AND actor.cell_x BETWEEN floor((p_player.x - reach) / 64)::integer
                               AND floor((p_player.x + reach) / 64)::integer
          AND actor.x BETWEEN p_player.x - reach AND p_player.x + reach
          AND actor.y BETWEEN p_player.y - reach AND p_player.y + reach
          AND actor.z < p_player.z + p_height AND actor.z + kind.height > p_player.z
          AND (actor.x - p_player.x) ^ 2 + (actor.y - p_player.y) ^ 2 <= (p_radius + kind.radius) ^ 2
        ORDER BY actor.actor_id
    LOOP
        IF (pickup.item = 'health' AND p_player.health >= 100)
            OR (pickup.item = 'health-bonus' AND p_player.health >= 200)
            OR NOT ((pickup.sector_id = p_player.sector_id AND abs(pickup.x - p_player.x) < 0.000001
                                                         AND abs(pickup.y - p_player.y) < 0.000001)
                OR EXISTS (
                    SELECT FROM doom._ray_sectors(p_player, pickup.x - p_player.x, pickup.y - p_player.y,
                                                  greatest(p_player.z, pickup.z)) AS path
                    WHERE path.sector_id = pickup.sector_id AND path.end_t = 1 AND NOT path.end_blocked
                ))
        THEN
            CONTINUE;
        END IF;
        DELETE FROM doom.actors WHERE game_id = p_player.game_id AND actor_id = pickup.actor_id;
        IF pickup.item IN ('health', 'health-bonus') THEN
            p_player.health := least(CASE WHEN pickup.item = 'health' THEN 100 ELSE 200 END,
                                     p_player.health + pickup.amount);
        ELSE
            INSERT INTO doom.game_inventory AS held (game_id, item, amount)
            VALUES (p_player.game_id, CASE WHEN pickup.item = 'armor-bonus' THEN 'armor' ELSE pickup.item END,
                    pickup.amount)
            ON CONFLICT (game_id, item) DO UPDATE SET amount = CASE
                WHEN pickup.item = 'armor' THEN greatest(held.amount, excluded.amount)
                ELSE least(1000000, held.amount::bigint + excluded.amount) END;
        END IF;
    END LOOP;
    RETURN p_player;
END;
$$;

CREATE FUNCTION doom._monster_turns(p_player doom.actors, p_tic bigint)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    candidate record;
    monster doom.actors;
    destination doom.actors;
    dx double precision;
    dy double precision;
    distance double precision;
    damage integer := 0;
    due_slot integer := (p_tic % 8)::integer;
BEGIN
    -- Slots avoid scanning or rescheduling faraway monsters every tick.
    FOR candidate IN
        SELECT actor AS body, kind.move_speed, kind.height, kind.radius, kind.attack_range, kind.attack_damage
        FROM doom.actors AS actor
        JOIN doom.thing_types AS kind USING (type_id)
        WHERE actor.game_id = p_player.game_id AND actor.kind = 'monster' AND actor.life_state = 'alive'
          AND actor.think_slot = due_slot AND actor.next_think <= p_tic
          AND actor.x BETWEEN p_player.x - 320 AND p_player.x + 320
          AND actor.y BETWEEN p_player.y - 320 AND p_player.y + 320
        ORDER BY actor.actor_id
    LOOP
        monster := candidate.body;
        dx := p_player.x - monster.x;
        dy := p_player.y - monster.y;
        distance := sqrt(dx * dx + dy * dy);
        IF distance > 320 OR distance < 0.000001 OR NOT EXISTS (
            SELECT FROM doom._ray_sectors(monster, dx, dy, doom._eye_z(monster.z)) AS path
            WHERE path.sector_id = p_player.sector_id AND path.end_t = 1 AND NOT path.end_blocked
        ) THEN
            CONTINUE;
        END IF;

        IF distance <= candidate.attack_range AND doom._eye_z(monster.z) BETWEEN p_player.z AND p_player.z + 55 THEN
            damage := damage + candidate.attack_damage;
            UPDATE doom.actors SET angle = atan2(dy, dx), next_think = p_tic + 21
            WHERE game_id = monster.game_id AND actor_id = monster.actor_id;
        ELSE
            destination := doom._move_actor(monster, dx * least(1, candidate.move_speed / distance),
                dy * least(1, candidate.move_speed / distance), candidate.height, candidate.radius);
            UPDATE doom.actors
            SET x = destination.x, y = destination.y, z = destination.z,
                sector_id = destination.sector_id, angle = atan2(dy, dx)
            WHERE game_id = monster.game_id AND actor_id = monster.actor_id
              AND (x, y, z, sector_id, angle) IS DISTINCT FROM (
                  destination.x, destination.y, destination.z, destination.sector_id, atan2(dy, dx));
        END IF;
    END LOOP;
    IF damage > 0 THEN
        damage := damage - doom._spend_inventory(p_player.game_id, 'armor', damage / 3);
        PERFORM doom._hurt(p_player.game_id, p_player.actor_id, damage, p_tic);
    END IF;
END;
$$;
