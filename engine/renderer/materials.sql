CREATE FUNCTION doom._sample_render_rows(
    p_level_id bigint, p_spans doom._render_span[], p_center_y double precision, p_changes_only boolean,
    p_column_major boolean DEFAULT false
)
RETURNS TABLE(ordinal integer, rgb bytea)
LANGUAGE sql STABLE PARALLEL SAFE
BEGIN ATOMIC
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
               CASE
                   WHEN needed.light = 255 THEN base.palette
                   WHEN needed.light BETWEEN 0 AND 254
                       THEN substring(base.shade_bytes FROM needed.light * 768 + 1 FOR 768)
                   WHEN needed.light IS NOT NULL THEN (
                       SELECT decode(string_agg(lpad(to_hex(
                           (get_byte(base.palette, channel) * needed.light + 127) / 255
                       ), 2, '0'), '' ORDER BY channel), 'hex')
                       FROM generate_series(0, 767) AS channels(channel)
                   )
               END AS colors
        FROM doom.level_palettes AS base
        CROSS JOIN (
            SELECT DISTINCT spans.light FROM spans
            JOIN materials ON materials.surface_kind = spans.surface_kind AND materials.name = spans.material_name
        ) AS needed
        WHERE base.level_id = p_level_id
    )
    SELECT sampled.ordinal, sampled.rgb
    FROM spans AS span
    LEFT JOIN materials AS material ON material.surface_kind = span.surface_kind AND material.name = span.material_name
    LEFT JOIN palettes AS palette ON palette.light = span.light
    CROSS JOIN LATERAL (
        WITH pixels AS NOT MATERIALIZED (
            SELECT raster.y,
                   CASE WHEN get_byte(material.coverage, raster.texel) > 0
                        THEN substring(palette.colors FROM 3 * get_byte(material.pixels, raster.texel) + 1 FOR 3)
                        ELSE span.rgb END AS rgb
            FROM (
                SELECT pixel.y, CASE
                    WHEN palette.colors IS NOT NULL AND material.width IS NOT NULL
                        AND (abs(sample.u) < 9223372036854775808::double precision OR sample.u = -9223372036854775808::double precision)
                        AND (abs(sample.v) < 9223372036854775808::double precision OR sample.v = -9223372036854775808::double precision)
                    THEN ((((sample.u::bigint % material.width) + material.width) % material.width) * material.height
                        + ((sample.v::bigint % material.height) + material.height) % material.height)::integer
                END AS texel
                FROM generate_series(span.row_start,
                    CASE WHEN (p_changes_only OR p_column_major) AND (material.width IS NULL OR palette.colors IS NULL)
                         THEN span.row_start ELSE span.row_end - 1 END
                ) AS pixel(y)
                CROSS JOIN LATERAL (SELECT nullif(pixel.y + 0.5::double precision - p_center_y, 0) AS distance) AS plane
                CROSS JOIN LATERAL (SELECT
                    floor(CASE WHEN span.radial THEN span.u + span.du / plane.distance ELSE span.u + span.du * pixel.y END) AS u,
                    floor(CASE WHEN span.radial THEN span.v + span.dv / plane.distance ELSE span.v + span.dv * pixel.y END) AS v
                ) AS sample
                -- Project the texel with the generated row and share it across both byte lookups.
                OFFSET 0
            ) AS raster
        )
        -- Both coordinates fit uint16. The combined key gives their packet byte order.
        SELECT (pixels.y << 16) | span.column_x AS ordinal, pixels.rgb
        FROM pixels WHERE NOT p_column_major
        UNION ALL
        SELECT (span.column_x << 16) | span.row_start,
               CASE WHEN material.width IS NULL OR palette.colors IS NULL
                    THEN decode(repeat(encode(span.rgb, 'hex'), span.row_end - span.row_start), 'hex')
                    ELSE string_agg(pixels.rgb, ''::bytea ORDER BY pixels.y) END
        FROM pixels WHERE p_column_major
        HAVING p_column_major
    ) AS sampled
    -- Keep material bytea fields out of the presorted aggregate's input sort.
    OFFSET 0;
END;

CREATE FUNCTION doom._sample_render_frame(
    p_level_id bigint, p_spans doom._render_span[], p_center_y double precision, p_span_packet boolean,
    p_column_major boolean DEFAULT false
)
RETURNS bytea
LANGUAGE sql STABLE STRICT PARALLEL SAFE
RETURN (
    SELECT string_agg(
        CASE WHEN p_span_packet THEN int4send(sampled.ordinal) || sampled.rgb ELSE sampled.rgb END,
        ''::bytea ORDER BY sampled.ordinal
    )
    FROM doom._sample_render_rows(p_level_id, p_spans, p_center_y, p_span_packet, p_column_major) AS sampled
);

CREATE FUNCTION doom._render_change_count(p_level_id bigint, p_spans doom._render_span[])
RETURNS bigint
LANGUAGE sql STABLE STRICT PARALLEL SAFE
RETURN cardinality(p_spans)::bigint + CASE
    WHEN EXISTS (SELECT FROM doom.level_palettes WHERE level_id = p_level_id) THEN (
        -- A span always emits its start. Only sampleable mappings emit the remaining rows.
        SELECT coalesce(sum(needed.extra_rows), 0)::bigint
        FROM (
            SELECT (span.mapping).surface_kind AS surface_kind,
                   upper((span.mapping).material_name COLLATE "C") AS material_name,
                   sum(span.row_end - span.row_start - 1) AS extra_rows
            FROM unnest(p_spans) AS span
            WHERE (span.mapping).light IS NOT NULL AND (span.mapping).material_name IS NOT NULL
              AND span.row_end - span.row_start > 1
            GROUP BY 1, 2
        ) AS needed
        JOIN doom.level_materials AS material ON material.level_id = p_level_id
            AND material.surface_kind = needed.surface_kind AND material.name = needed.material_name
    ) ELSE 0 END;
