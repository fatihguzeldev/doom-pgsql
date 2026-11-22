CREATE TYPE doom._shot_contact AS (
    actor_id bigint,
    distance double precision
);

CREATE FUNCTION doom._ray_hit(p_actor doom.actors, p_range double precision, p_z double precision)
RETURNS doom._shot_contact
LANGUAGE plpgsql STABLE STRICT
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
    bucket_reach double precision;
BEGIN
    IF p_range < axis_slop OR p_range >= 'Infinity' OR abs(p_z) >= 'Infinity' THEN
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

    SELECT ceil(ceil(max(radius)) / 64) INTO bucket_reach FROM doom.actor_types;

    RETURN (
    WITH path AS (
        SELECT span.*,
               max(span.end_t) FILTER (WHERE span.end_blocked) OVER () AS blocked_t
        FROM doom._ray_sectors(p_actor, ray_dx, ray_dy, p_z) AS span
    )
    SELECT ROW(target.actor_id, target.distance)::doom._shot_contact
    FROM path
    CROSS JOIN LATERAL (
        SELECT actor.actor_id, contact.distance
        FROM doom.actors AS actor
        JOIN doom.actor_types AS kind ON kind.kind = actor.kind
        CROSS JOIN LATERAL (
            SELECT actor.x - p_actor.x AS x, actor.y - p_actor.y AS y
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
        WHERE actor.game_id = p_actor.game_id AND actor.sector_id = path.sector_id
          AND actor.actor_id IS DISTINCT FROM p_actor.actor_id AND actor.health > 0
          AND kind.radius > 0 AND actor.z <= p_z AND p_z - actor.z < kind.height
          AND actor.collision_x_bucket BETWEEN
              floor(floor(p_actor.x + least(ray_dx * path.start_t, ray_dx * path.end_t)) / 64) - bucket_reach
              AND floor(floor(p_actor.x + greatest(ray_dx * path.start_t, ray_dx * path.end_t)) / 64) + bucket_reach
          AND relative.x BETWEEN least(ray_dx * path.start_t, ray_dx * path.end_t) - kind.radius
                             AND greatest(ray_dx * path.start_t, ray_dx * path.end_t) + kind.radius
          AND relative.y BETWEEN least(ray_dy * path.start_t, ray_dy * path.end_t) - kind.radius
                             AND greatest(ray_dy * path.start_t, ray_dy * path.end_t) + kind.radius
          AND projected.along + cylinder.half_chord >= path.start_t * ray_length - contact.error_margin
          AND contact.distance - path.end_t * ray_length <= contact.error_margin
          -- A distance rounded just inside the wall still belongs to the blocked endpoint.
          AND (path.blocked_t IS NULL OR path.blocked_t * ray_length - contact.distance > contact.error_margin)
        ORDER BY contact.distance, actor.actor_id
        LIMIT 1
    ) AS target
    WHERE path.start_t < path.end_t
    ORDER BY target.distance, target.actor_id
    LIMIT 1
    );
END;
$$;

CREATE FUNCTION doom._ray_target(p_actor doom.actors, p_range double precision, p_z double precision)
RETURNS bigint
LANGUAGE sql STABLE STRICT
RETURN (doom._ray_hit(p_actor, p_range, p_z)).actor_id;
