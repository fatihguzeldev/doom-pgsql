CREATE FUNCTION doom._circle_segment_contact(
    p_x double precision, p_y double precision,
    p_dx double precision, p_dy double precision, p_radius double precision,
    p_x1 double precision, p_y1 double precision, p_x2 double precision, p_y2 double precision
)
RETURNS double precision
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
AS $$
DECLARE
    roundoff CONSTANT double precision := 8.881784197001252e-16;
    edge_x double precision;
    edge_y double precision;
    edge_squared double precision;
    start_x double precision;
    start_y double precision;
    end_x double precision;
    end_y double precision;
    projection double precision;
    projection_motion double precision;
    contact_projection double precision;
    line_offset double precision;
    strip_radius double precision;
    toward_line double precision;
    gap double precision;
    contact double precision;
    radius_squared double precision;
    endpoint_x double precision;
    endpoint_y double precision;
    toward_endpoint double precision;
    endpoint_squared double precision;
    radius_motion_squared double precision;
    cross_x double precision;
    cross_y double precision;
    cross_motion double precision;
    discriminant double precision;
    root_scale double precision;
    earliest double precision;
BEGIN
    IF p_radius <= 0 OR (p_dx = 0 AND p_dy = 0)
        OR greatest(abs(p_x), abs(p_y), abs(p_dx), abs(p_dy), p_radius,
                    abs(p_x1), abs(p_y1), abs(p_x2), abs(p_y2)) >= 'Infinity'
    THEN
        RETURN NULL;
    END IF;

    edge_x := p_x2 - p_x1;
    edge_y := p_y2 - p_y1;
    edge_squared := edge_x * edge_x + edge_y * edge_y;
    start_x := p_x - p_x1;
    start_y := p_y - p_y1;
    end_x := p_x - p_x2;
    end_y := p_y - p_y2;
    projection := start_x * edge_x + start_y * edge_y;
    radius_squared := p_radius * p_radius;

    -- From an existing overlap the squared distance to the segment is convex
    -- in time, so only an initially inward velocity can deepen the overlap.
    IF edge_squared = 0 OR projection <= 0 OR projection >= edge_squared THEN
        IF projection > 0 THEN
            endpoint_x := end_x;
            endpoint_y := end_y;
        ELSE
            endpoint_x := start_x;
            endpoint_y := start_y;
        END IF;

        IF endpoint_x * endpoint_x + endpoint_y * endpoint_y <= radius_squared THEN
            RETURN CASE WHEN endpoint_x * p_dx + endpoint_y * p_dy < 0 THEN 0.0 END;
        END IF;
    END IF;

    IF edge_squared > 0 THEN
        line_offset := start_x * edge_y - start_y * edge_x;
        strip_radius := p_radius * sqrt(edge_squared);
        toward_line := p_dy * edge_x - p_dx * edge_y;
        IF line_offset < 0 THEN
            toward_line := -toward_line;
        END IF;
        gap := abs(line_offset) - strip_radius;

        IF gap <= 0 AND projection BETWEEN 0 AND edge_squared THEN
            RETURN CASE WHEN line_offset <> 0 AND toward_line > 0 THEN 0.0 END;
        END IF;

        projection_motion := p_dx * edge_x + p_dy * edge_y;
        IF gap > 0 AND toward_line > 0
            AND gap - toward_line <= roundoff * (abs(line_offset) + strip_radius)
        THEN
            contact := CASE WHEN gap >= toward_line THEN 1.0 ELSE gap / toward_line END;
            contact_projection := projection + contact * projection_motion;
            IF contact_projection BETWEEN 0 AND edge_squared THEN
                -- Before reaching the strip the center is outside both endpoint disks.
                RETURN contact;
            END IF;
        END IF;

        IF projection BETWEEN 0 AND edge_squared
            AND projection + projection_motion BETWEEN 0 AND edge_squared
        THEN
            RETURN NULL;
        END IF;
    END IF;

    radius_motion_squared := radius_squared * (p_dx * p_dx + p_dy * p_dy);
    FOR endpoint IN 1..2 LOOP
        IF endpoint = 1 THEN
            endpoint_x := start_x;
            endpoint_y := start_y;
        ELSE
            EXIT WHEN edge_squared = 0;
            endpoint_x := end_x;
            endpoint_y := end_y;
        END IF;

        toward_endpoint := -(endpoint_x * p_dx + endpoint_y * p_dy);
        IF toward_endpoint > 0 THEN
            cross_x := endpoint_x * p_dy;
            cross_y := endpoint_y * p_dx;
            cross_motion := cross_x - cross_y;
            discriminant := radius_motion_squared - cross_motion * cross_motion;
            -- Roundoff in the determinant can place an exact graze just inside the disk.
            IF discriminant > roundoff * (radius_motion_squared + abs(cross_motion) * (abs(cross_x) + abs(cross_y))) THEN
                -- The equivalent near root avoids cancellation next to the boundary.
                endpoint_squared := endpoint_x * endpoint_x + endpoint_y * endpoint_y;
                gap := endpoint_squared - radius_squared;
                root_scale := toward_endpoint + sqrt(discriminant);
                IF gap - root_scale <= roundoff * (endpoint_squared + radius_squared) THEN
                    contact := CASE WHEN gap >= root_scale THEN 1.0 ELSE greatest(0.0, gap) / root_scale END;
                    earliest := least(earliest, contact);
                END IF;
            END IF;
        END IF;
    END LOOP;

    RETURN earliest;
END;
$$;
