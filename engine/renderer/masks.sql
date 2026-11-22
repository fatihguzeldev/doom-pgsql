CREATE FUNCTION doom._clip_masked_render_spans(p_level_id bigint, p_overlays doom._render_span[])
RETURNS doom._render_span[]
LANGUAGE sql STABLE STRICT PARALLEL SAFE
RETURN (
    WITH overlays AS MATERIALIZED (
        SELECT span.*, (span.mapping).surface_kind AS surface_kind,
               upper((span.mapping).material_name COLLATE "C") AS material_name,
               (span.mapping).v AS mapping_v, (span.mapping).dv AS mapping_dv
        FROM unnest(p_overlays) WITH ORDINALITY AS span(column_x, row_start, row_end, rgb, mapping, depth_order)
    ), materials AS MATERIALIZED (
        SELECT material.surface_kind, material.name, material.width, material.height,
               substring(material.coverage FROM 1) AS coverage
        FROM doom.level_materials AS material
        JOIN (SELECT DISTINCT surface_kind, material_name FROM overlays
              WHERE surface_kind IN ('wall', 'sprite') AND material_name IS NOT NULL) AS needed
          ON needed.surface_kind = material.surface_kind AND needed.material_name = material.name
        WHERE material.level_id = p_level_id
    ), mapped_columns AS MATERIALIZED (
        -- Fix the source column before expanding rows, without copying coverage in each span.
        SELECT layer.depth_order, layer.row_start, layer.row_end, layer.surface_kind, layer.material_name,
               layer.mapping_v, layer.mapping_dv, material.height,
               CASE WHEN layer.surface_kind = 'sprite' THEN CASE
                    WHEN horizontal.u >= 0 AND horizontal.u < material.width THEN horizontal.u::bigint
               END
               WHEN horizontal.u >= -9223372036854775808::double precision
                    AND horizontal.u < 9223372036854775808::double precision
               THEN ((horizontal.u::bigint % material.width + material.width) % material.width)
               END * material.height AS base_texel
        FROM overlays AS layer
        JOIN materials AS material ON material.surface_kind = layer.surface_kind AND material.name = layer.material_name
        CROSS JOIN LATERAL (SELECT floor((layer.mapping).u) AS u) AS horizontal
    ), opaque_runs AS (
        SELECT layer.depth_order, range_agg(int4range(pixel.y, pixel.y + 1)) AS rows
        FROM mapped_columns AS layer
        JOIN materials AS material ON material.surface_kind = layer.surface_kind AND material.name = layer.material_name
        CROSS JOIN LATERAL generate_series(layer.row_start, layer.row_end - 1) AS pixel(y)
        CROSS JOIN LATERAL (SELECT layer.mapping_v + layer.mapping_dv * pixel.y AS v) AS vertical
        WHERE layer.base_texel IS NOT NULL
          AND get_byte(material.coverage, CASE WHEN vertical.v >= 0 AND vertical.v < layer.height
                THEN layer.base_texel::integer + floor(vertical.v)::integer END) > 0
        GROUP BY layer.depth_order
    )
    SELECT coalesce(array_agg(
        ROW(layer.column_x, lower(visible.rows), upper(visible.rows), layer.rgb, layer.mapping)::doom._render_span
        ORDER BY layer.depth_order, lower(visible.rows)
    ), '{}'::doom._render_span[])
    FROM overlays AS layer
    LEFT JOIN opaque_runs AS opaque USING (depth_order)
    CROSS JOIN LATERAL unnest(CASE WHEN layer.mapping IS NULL
        THEN int4multirange(int4range(layer.row_start, layer.row_end)) ELSE opaque.rows END) AS visible(rows)
);
