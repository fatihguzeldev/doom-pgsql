CREATE TABLE doom._flat_atlas (
    level_id bigint NOT NULL REFERENCES doom.levels ON DELETE CASCADE,
    name text NOT NULL,
    mip smallint NOT NULL,
    du smallint NOT NULL,
    dv smallint NOT NULL,
    page integer NOT NULL,
    colors bytea NOT NULL,
    PRIMARY KEY (level_id, name, mip, du, dv, page)
);

CREATE FUNCTION doom._flat_atlas_key(
    p_width integer, p_u double precision, p_v double precision,
    p_du double precision, p_dv double precision
) RETURNS TABLE(mip integer, dir_u integer, dir_v integer, page integer, first_byte integer)
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE ROWS 1 AS $$
DECLARE
    scale integer := 1;
    grid integer;
    a integer;
    b integer;
    u integer;
    v integer;
    divisor integer;
    period integer;
    mask integer;
    major integer;
    minor integer;
    inverse integer;
    phase integer;
    orbit integer;
    stride integer;
BEGIN
    IF p_width NOT BETWEEN 4 AND 64 OR (p_width & (p_width - 1)) <> 0
        OR NOT (abs(p_u) < 1e15 AND abs(p_v) < 1e15)
    THEN
        RETURN;
    END IF;
    WHILE greatest(abs(p_du), abs(p_dv)) > scale LOOP
        scale := scale * 2;
        IF scale > p_width THEN
            RETURN;
        END IF;
    END LOOP;
    mip := p_width / scale;
    grid := 4 * mip;
    -- Floor anchors preserve lower texel ownership at a cell boundary.
    u := floor(p_u * 4 / scale)::bigint & (grid - 1);
    v := floor(p_v * 4 / scale)::bigint & (grid - 1);
    a := round(p_du * 4 / scale)::integer;
    b := round(p_dv * 4 / scale)::integer;
    IF a = 0 AND b = 0 THEN
        RETURN;
    END IF;
    dir_u := a;
    dir_v := b;
    divisor := gcd(grid, gcd(a, b));
    period := grid / divisor;
    mask := period - 1;
    major := a / divisor;
    minor := b / divisor;
    IF (major & 1) = 0 THEN
        SELECT v, u, minor, major INTO u, v, major, minor;
    END IF;
    -- The odd component is ±1 or ±3. Invert it in the power-of-two period.
    inverse := CASE abs(major) WHEN 1 THEN 1
        ELSE (period * (1 + (period % 3 = 1)::integer) + 1) / 3 END;
    phase := (inverse * sign(major)::integer * (u / divisor)) & mask;
    orbit := ((u % divisor) * divisor + v % divisor) * period
        + (((v / divisor) - phase * minor) & mask);
    stride := greatest(2 * period, 16);
    page := orbit / (2048 / stride);
    first_byte := (orbit % (2048 / stride)) * stride + phase + 1;
    RETURN NEXT;
END;
$$;

CREATE FUNCTION doom._compile_flat_atlas(p_level_id bigint)
RETURNS void LANGUAGE plpgsql STRICT SET jit = off AS $$
DECLARE
    asset record;
    mip integer;
    scale integer;
    grid integer;
    a integer;
    b integer;
    divisor integer;
    period integer;
    major integer;
    minor integer;
    swapped boolean;
    stride integer;
    texel_shift integer;
    phase_mask integer;
    mip_pixels bytea;
    mip_transposed bytea;
    sample_pixels bytea;
BEGIN
    DELETE FROM doom._flat_atlas WHERE level_id = p_level_id;
    FOR asset IN
        SELECT material.name, material.width, substring(material.pixels FROM 1) AS pixels
        FROM doom.level_materials AS material
        WHERE material.level_id = p_level_id AND material.surface_kind = 'flat'
            AND material.width = material.height AND material.width BETWEEN 4 AND 64
            AND (material.width & (material.width - 1)) = 0
            AND EXISTS (SELECT FROM doom.sectors AS sector WHERE sector.level_id = p_level_id
                AND material.name IN (sector.floor_material, sector.ceiling_material))
    LOOP
        mip := asset.width;
        WHILE mip > 0 LOOP
            scale := asset.width / mip;
            grid := mip * 4;
            SELECT string_agg(substring(asset.pixels FROM 1 + sample.y * asset.width + sample.x FOR 1),
                              ''::bytea ORDER BY sample.y, sample.x),
                   string_agg(substring(asset.pixels FROM 1 + sample.y * asset.width + sample.x FOR 1),
                              ''::bytea ORDER BY sample.x, sample.y)
            INTO mip_pixels, mip_transposed
            FROM generate_series(0, asset.width - 1, scale) AS sample_x(x)
            CROSS JOIN generate_series(0, asset.width - 1, scale) AS sample_y(y)
            CROSS JOIN LATERAL (SELECT sample_x.x, sample_y.y) AS sample;

            FOR a IN -4..4 LOOP
                FOR b IN -4..4 LOOP
                    IF a = 0 AND b = 0 THEN
                        CONTINUE;
                    END IF;
                    divisor := gcd(grid, gcd(a, b));
                    period := grid / divisor;
                    major := a / divisor;
                    minor := b / divisor;
                    swapped := (major & 1) = 0;
                    IF swapped THEN
                        SELECT minor, major INTO major, minor;
                    END IF;
                    sample_pixels := CASE WHEN swapped THEN mip_transposed ELSE mip_pixels END;
                    texel_shift := CASE divisor WHEN 4 THEN 0 WHEN 2 THEN 1 ELSE 2 END;
                    phase_mask := period - 1;
                    stride := greatest(2 * period, 16);
                    INSERT INTO doom._flat_atlas (level_id, name, mip, du, dv, page, colors)
                    WITH cycles AS MATERIALIZED (
                        -- Subtexel remainders below divisor cannot change a sampled texel.
                        SELECT orbit.n,
                               string_agg(CASE WHEN period < 4
                                   THEN substring(sample_pixels FROM texel.i0 + 1 FOR 1)
                                   -- Aggregate network-order words to emit four consecutive color bytes.
                                   ELSE int4send(
                                       (get_byte(sample_pixels, texel.i0) << 24)
                                       | (get_byte(sample_pixels, texel.i1) << 16)
                                       | (get_byte(sample_pixels, texel.i2) << 8)
                                       | get_byte(sample_pixels, texel.i3)
                                   ) END, ''::bytea ORDER BY phase.n) AS colors
                        FROM generate_series(0, period - 1) AS orbit(n)
                        CROSS JOIN generate_series(0, period - 1, CASE WHEN period < 4 THEN 1 ELSE 4 END) AS phase(n)
                        CROSS JOIN LATERAL (
                            SELECT phase.n * major AS x, orbit.n + phase.n * minor AS y
                        ) AS step
                        CROSS JOIN LATERAL (
                            SELECT ((step.y & phase_mask) >> texel_shift) * mip
                                       + ((step.x & phase_mask) >> texel_shift) AS i0,
                                   (((step.y + minor) & phase_mask) >> texel_shift) * mip
                                       + (((step.x + major) & phase_mask) >> texel_shift) AS i1,
                                   (((step.y + 2 * minor) & phase_mask) >> texel_shift) * mip
                                       + (((step.x + 2 * major) & phase_mask) >> texel_shift) AS i2,
                                   (((step.y + 3 * minor) & phase_mask) >> texel_shift) * mip
                                       + (((step.x + 3 * major) & phase_mask) >> texel_shift) AS i3
                        ) AS texel
                        GROUP BY orbit.n
                    ), repeated AS MATERIALIZED (
                        SELECT cycles.n, CASE WHEN stride = 2 * period THEN cycles.colors || cycles.colors
                            ELSE decode(repeat(encode(cycles.colors, 'hex'), stride / period), 'hex')
                            END AS colors
                        FROM cycles
                    )
                    SELECT p_level_id, asset.name, mip, a, b, output.slot / (2048 / stride),
                           string_agg(repeated.colors, ''::bytea ORDER BY output.slot)
                    FROM repeated
                    CROSS JOIN generate_series(0, divisor * divisor - 1) AS replica(n)
                    CROSS JOIN LATERAL (SELECT replica.n * period + repeated.n AS slot) AS output
                    GROUP BY output.slot / (2048 / stride);
                END LOOP;
            END LOOP;
            mip := mip / 2;
        END LOOP;
    END LOOP;
END;
$$;
