CREATE FUNCTION doom._actor_contact(
    p_actor doom.actors, p_dx double precision, p_dy double precision,
    p_height double precision, p_radius double precision, p_bodies doom._sim_body[]
)
RETURNS double precision
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    candidate record;
    contact_actor doom.actors := p_actor;
    reached doom.actors;
    left_x double precision := least(p_actor.x, p_actor.x + p_dx) - p_radius;
    right_x double precision := greatest(p_actor.x, p_actor.x + p_dx) + p_radius;
    bottom_y double precision := least(p_actor.y, p_actor.y + p_dy) - p_radius;
    top_y double precision := greatest(p_actor.y, p_actor.y + p_dy) + p_radius;
    bucket_reach double precision;
    left_bucket double precision;
    right_bucket double precision;
BEGIN
    IF p_actor IS NULL OR p_dx IS NULL OR p_dy IS NULL OR p_height IS NULL
        OR p_radius IS NULL OR p_radius <= 0 OR (p_dx = 0 AND p_dy = 0)
    THEN
        RETURN NULL;
    END IF;

    IF p_bodies IS NULL THEN
        -- Round the largest blocker radius up to whole buckets for the index scan.
        SELECT ceil(ceil(max(radius)) / 64) INTO bucket_reach
        FROM doom.actor_types WHERE blocks_actors AND radius > 0;
        IF bucket_reach IS NULL THEN
            RETURN NULL;
        END IF;
        left_bucket := floor(floor(left_x) / 64) - bucket_reach;
        right_bucket := floor(floor(right_x) / 64) + bucket_reach;
    END IF;

    FOR candidate IN
        SELECT body.x, body.y, body.sector_id,
               doom._circle_segment_contact(p_actor.x, p_actor.y, p_dx, p_dy, p_radius + body.radius,
                                            body.x, body.y, body.x, body.y) AS contact_at
        FROM (
            SELECT actor.actor_id, actor.sector_id, actor.x, actor.y, actor.z, kind.height, kind.radius
            FROM doom.actors AS actor
            JOIN doom.actor_types AS kind ON kind.kind = actor.kind
            WHERE p_bodies IS NULL AND actor.game_id = p_actor.game_id
              AND actor.collision_x_bucket BETWEEN left_bucket AND right_bucket
              AND actor.health > 0 AND kind.blocks_actors AND kind.radius > 0
            UNION ALL
            SELECT current_body.actor_id, current_body.sector_id, current_body.x, current_body.y,
                   current_body.z, current_body.height, current_body.radius
            FROM unnest(p_bodies) AS current_body
            WHERE current_body.blocks_actors
        ) AS body
        WHERE body.actor_id IS DISTINCT FROM p_actor.actor_id
          AND body.x BETWEEN left_x - body.radius AND right_x + body.radius
          AND body.y BETWEEN bottom_y - body.radius AND top_y + body.radius
          AND body.z < p_actor.z + p_height AND body.z + body.height > p_actor.z
        ORDER BY contact_at
    LOOP
        EXIT WHEN candidate.contact_at IS NULL;

        -- A wall can separate overlapping disks, even within one sector.
        contact_actor.x := p_actor.x + p_dx * candidate.contact_at;
        contact_actor.y := p_actor.y + p_dy * candidate.contact_at;
        reached := doom._move_actor(contact_actor, candidate.x - contact_actor.x,
                                    candidate.y - contact_actor.y, p_height, 0, p_bodies);
        IF reached.sector_id = candidate.sector_id
            AND abs(reached.x - candidate.x) < 0.000001 AND abs(reached.y - candidate.y) < 0.000001
        THEN
            RETURN candidate.contact_at;
        END IF;
    END LOOP;

    RETURN NULL;
END;
$$;
