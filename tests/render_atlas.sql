\set ON_ERROR_STOP on
BEGIN;
DO $$
DECLARE
    map bigint;
    sample record;
    found_bytes bytea;
    expected bytea;
    selected_mip integer;
BEGIN
    INSERT INTO doom.levels (name) VALUES ('atlas') RETURNING level_id INTO map;
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height, floor_material)
        VALUES (map, 0, 0, 64, 'ATLAS');
    INSERT INTO doom.level_materials (level_id, surface_kind, name, width, height, pixels, coverage)
        VALUES (map, 'flat', 'ATLAS', 4, 4, '\x000102030405060708090a0b0c0d0e0f', decode(repeat('ff', 16), 'hex'));
    PERFORM doom._compile_flat_atlas(map);
    FOR sample IN SELECT origin.x, origin.y, step.du / 4.0::float8 AS du, step.dv / 4.0::float8 AS dv
        FROM (VALUES (0.5::float8, 1.25::float8), (3.25, -2.5), (-7.75, 7.0)) AS origin(x,y)
        CROSS JOIN generate_series(-4,4) AS step_u(du)
        CROSS JOIN LATERAL (SELECT step_u.du, n AS dv FROM generate_series(-4,4) AS n) AS step
        WHERE step.du <> 0 OR step.dv <> 0
    LOOP
        SELECT substring(atlas.colors FROM address.first_byte FOR 8), address.mip
        INTO STRICT found_bytes, selected_mip
        FROM doom._flat_atlas_key(4, sample.x, sample.y, sample.du, sample.dv) AS address
        JOIN doom._flat_atlas AS atlas ON atlas.level_id = map AND atlas.name = 'ATLAS'
            AND atlas.mip = address.mip AND atlas.du = address.dir_u AND atlas.dv = address.dir_v
            AND atlas.page = address.page;
        SELECT decode(string_agg(lpad(to_hex(((floor(sample.y + sample.dv * n)::integer & 3) * 4)
            + (floor(sample.x + sample.du * n)::integer & 3)), 2, '0'), '' ORDER BY n), 'hex')
        INTO expected FROM generate_series(0,7) AS n;
        IF selected_mip <> 4 OR found_bytes <> expected THEN
            RAISE EXCEPTION 'atlas mismatch for %: % vs %', sample, found_bytes, expected;
        END IF;
    END LOOP;
END;
$$;
ROLLBACK;
