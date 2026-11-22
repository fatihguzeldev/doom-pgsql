\set ON_ERROR_STOP on
BEGIN;

DO $$
DECLARE
    test_level bigint;
    spans doom._render_span[];
    expected_rgb bytea;
    expected_packet bytea;
    observed bytea;
BEGIN
    INSERT INTO doom.levels (name) VALUES ('Raster span sampling fixture')
    RETURNING level_id INTO test_level;

    INSERT INTO doom.level_palettes (level_id, palette)
    VALUES (test_level, decode('0a141e1122332244663366994488cc55aaff' || repeat('00', 750), 'hex'));

    INSERT INTO doom.level_materials (level_id, surface_kind, name, width, height, pixels, coverage)
    SELECT test_level, fixture.kind, 'CHECKER', 3, 2, fixture.pixels, fixture.coverage
    FROM (VALUES
        ('wall', '\x000102030405'::bytea, '\xff0001ffffff'::bytea),
        ('flat', '\x050403020100'::bytea, '\xffffffffffff'::bytea),
        ('sprite', '\x010203040500'::bytea, '\xffffffffffff'::bytea)
    ) AS fixture(kind, pixels, coverage);

    spans := ARRAY[
        ROW(0, 0, 4, '\x334455', ROW('wall', 'checker', 255, -0.25, -1.25, 0, 1, false)::doom._render_mapping),
        ROW(0, 4, 5, '\x112200', NULL),
        ROW(1, 0, 5, '\x8a7b6c', ROW('flat', 'CHECKER', 127, 0.5, 0.75, 2, 2, true)::doom._render_mapping),
        ROW(2, 0, 2, '\xa1a2a3', NULL),
        ROW(2, 2, 4, '\x101010', ROW('wall', 'MISSING', 255, 0, 0, 0, 0, false)::doom._render_mapping),
        ROW(2, 4, 5, '\x556677', ROW('sprite', 'CHECKER', 255, 1, 0, 0, 0, false)::doom._render_mapping),
        ROW(3, 0, 1, '\xcc3344',
            ROW('wall', 'CHECKER', 255, '-9223372036854777856', 0, 0, 0, false)::doom._render_mapping),
        ROW(3, 1, 2, '\xcc3344',
            ROW('wall', 'CHECKER', 255, '-9223372036854775808', 0, 0, 0, false)::doom._render_mapping),
        ROW(3, 2, 3, '\xcc3344',
            ROW('wall', 'CHECKER', 255, '9223372036854775808', 0, 0, 0, false)::doom._render_mapping),
        ROW(3, 3, 4, '\xcc3344',
            ROW('wall', 'CHECKER', 255, 0, '-9223372036854777856', 0, 0, false)::doom._render_mapping),
        ROW(3, 4, 5, '\xcc3344',
            ROW('wall', 'CHECKER', 255, 1, '-9223372036854775808', 0, 0, false)::doom._render_mapping),
        ROW(4, 0, 2, '\x789abc', ROW('wall', 'CHECKER', 255, 0, 1, 0, 0, false)::doom._render_mapping),
        ROW(4, 2, 5, '\x789abc', ROW('wall', 'CHECKER', 255, 0, 0, 1, 0, false)::doom._render_mapping)
    ]::doom._render_span[];

    -- Row two is the radial horizon. Its flat sample falls back without dividing by zero.
    -- Column three crosses the signed bigint sampling bounds, with the exact lower bound valid.
    expected_rgb := decode(
        '4488cc 050a0f a1a2a3 cc3344 789abc '
        || '55aaff 19334c a1a2a3 224466 789abc '
        || '4488cc 8a7b6c 101010 cc3344 4488cc '
        || '55aaff 081119 101010 cc3344 0a141e '
        || '112200 112233 336699 224466 224466', 'hex');

    observed := doom._sample_render_frame(test_level, spans, 2.5, false);
    IF observed IS DISTINCT FROM expected_rgb THEN
        RAISE EXCEPTION 'Unexpected mixed sampler output: %', encode(observed, 'hex');
    END IF;

    -- Solids and missing materials need only a start record. Mapped texels still emit each row.
    SELECT string_agg(int2send(y::smallint) || int2send(x::smallint)
        || substring(expected_rgb FROM 3 * (y * 5 + x) + 1 FOR 3), ''::bytea ORDER BY y, x)
    INTO expected_packet
    FROM generate_series(0, 4) AS y CROSS JOIN generate_series(0, 4) AS x
    WHERE x <> 2 OR y NOT IN (1, 3);

    IF doom._sample_render_frame(test_level, spans, 2.5, true) IS DISTINCT FROM expected_packet THEN
        RAISE EXCEPTION 'Mixed sampler packets must preserve exact texels and row-major changes';
    END IF;

    DELETE FROM doom.level_palettes WHERE level_id = test_level;
    SELECT string_agg(int2send(span.row_start::smallint) || int2send(span.column_x::smallint) || span.rgb,
        ''::bytea ORDER BY span.row_start, span.column_x)
    INTO expected_packet
    FROM unnest(spans) AS span;

    IF doom._sample_render_frame(test_level, spans, 2.5, true) IS DISTINCT FROM expected_packet THEN
        RAISE EXCEPTION 'Without a palette each span must emit only its start and solid color';
    END IF;
END;
$$;

ROLLBACK;
