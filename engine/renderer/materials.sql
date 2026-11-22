CREATE FUNCTION doom._sample_render_frame(
    p_level_id bigint, p_spans doom._render_span[], p_center_y double precision, p_span_packet boolean
)
RETURNS bytea
LANGUAGE sql STABLE STRICT PARALLEL SAFE
RETURN (
    WITH spans AS MATERIALIZED (
        SELECT span.column_x, span.row_start, span.row_end, span.rgb, mapping.surface_kind,
               upper(mapping.material_name COLLATE "C") AS material_name,
               mapping.light, mapping.u, mapping.v, mapping.du, mapping.dv, mapping.radial
        FROM unnest(p_spans) AS span
        CROSS JOIN LATERAL (SELECT (span.mapping).*) AS mapping
    ), materials AS MATERIALIZED (
        -- Fetch the stored planes once before any visible span expands into pixels.
        SELECT material.surface_kind, material.name, material.width, material.height,
               substring(material.pixels FROM 1) AS pixels,
               substring(material.coverage FROM 1) AS coverage
        FROM doom.level_materials AS material
        JOIN (SELECT DISTINCT surface_kind, material_name FROM spans WHERE material_name IS NOT NULL) AS needed
          ON needed.surface_kind = material.surface_kind AND needed.material_name = material.name
        WHERE material.level_id = p_level_id
    ), palettes AS MATERIALIZED (
        SELECT needed.light,
               CASE WHEN needed.light = 255 THEN base.palette ELSE (
                   SELECT decode(string_agg(lpad(to_hex(
                       (get_byte(base.palette, channel) * needed.light + 127) / 255
                   ), 2, '0'), '' ORDER BY channel), 'hex')
                   FROM generate_series(0, 767) AS channels(channel)
               ) END AS colors
        FROM doom.level_palettes AS base
        CROSS JOIN (
            SELECT DISTINCT spans.light FROM spans
            JOIN materials ON materials.surface_kind = spans.surface_kind AND materials.name = spans.material_name
        ) AS needed
        WHERE base.level_id = p_level_id
    )
    SELECT string_agg(
        CASE WHEN p_span_packet THEN int4send(sampled.ordinal) || sampled.rgb ELSE sampled.rgb END,
        ''::bytea ORDER BY sampled.ordinal
    )
    FROM (
        SELECT pixel_key.ordinal, color.rgb
        FROM spans AS span
        LEFT JOIN materials AS material ON material.surface_kind = span.surface_kind AND material.name = span.material_name
        LEFT JOIN palettes AS palette ON palette.light = span.light
        CROSS JOIN LATERAL generate_series(span.row_start,
            CASE WHEN p_span_packet AND (material.width IS NULL OR palette.colors IS NULL)
                 THEN span.row_start ELSE span.row_end - 1 END
        ) AS pixel(y)
        -- Both coordinates fit uint16. The combined key also gives their packet byte order.
        CROSS JOIN LATERAL (SELECT (pixel.y << 16) | span.column_x AS ordinal) AS pixel_key
        CROSS JOIN LATERAL (SELECT nullif(pixel.y + 0.5::double precision - p_center_y, 0) AS distance) AS plane
        CROSS JOIN LATERAL (SELECT
            floor(CASE WHEN span.radial THEN span.u + span.du / plane.distance ELSE span.u + span.du * pixel.y END) AS u,
            floor(CASE WHEN span.radial THEN span.v + span.dv / plane.distance ELSE span.v + span.dv * pixel.y END) AS v
        ) AS sample
        CROSS JOIN LATERAL (SELECT CASE
            WHEN palette.colors IS NOT NULL AND material.width IS NOT NULL
                AND sample.u >= -9223372036854775808::double precision AND sample.u < 9223372036854775808::double precision
                AND sample.v >= -9223372036854775808::double precision AND sample.v < 9223372036854775808::double precision
            THEN ((((sample.u::bigint % material.width) + material.width) % material.width) * material.height
                + ((sample.v::bigint % material.height) + material.height) % material.height)::integer
        END AS texel OFFSET 0) AS location
        CROSS JOIN LATERAL (SELECT
            CASE WHEN get_byte(material.coverage, location.texel) > 0
                 THEN substring(palette.colors FROM 3 * get_byte(material.pixels, location.texel) + 1 FOR 3)
                 ELSE span.rgb END AS rgb
        ) AS color
        -- Keep material bytea fields out of the presorted aggregate's input sort.
        OFFSET 0
    ) AS sampled
);
