BEGIN;

CREATE FUNCTION pg_temp.sprite_le32(p_value integer)
RETURNS bytea LANGUAGE sql IMMUTABLE STRICT
RETURN decode(lpad(to_hex(p_value & 255), 2, '0')
    || lpad(to_hex((p_value >> 8) & 255), 2, '0')
    || lpad(to_hex((p_value >> 16) & 255), 2, '0')
    || lpad(to_hex((p_value >> 24) & 255), 2, '0'), 'hex');

CREATE FUNCTION pg_temp.sprite_archive(p_names text[], p_data bytea[])
RETURNS bytea LANGUAGE sql IMMUTABLE STRICT
RETURN (
    WITH entries AS (
        SELECT name, payload, entry_index, octet_length(payload) AS size,
               12 + coalesce(sum(octet_length(payload)) OVER (
                   ORDER BY entry_index ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0)::integer AS position
        FROM unnest(p_names, p_data) WITH ORDINALITY AS entry(name, payload, entry_index)
    )
    SELECT '\x50574144'::bytea || pg_temp.sprite_le32(count(*)::integer)
        || pg_temp.sprite_le32(12 + sum(size)::integer)
        || string_agg(payload, '\x'::bytea ORDER BY entry_index)
        || string_agg(pg_temp.sprite_le32(position) || pg_temp.sprite_le32(size)
             || convert_to(name, 'LATIN1') || decode(repeat('00', 8 - length(name)), 'hex'),
             '\x'::bytea ORDER BY entry_index)
    FROM entries
);

DO $$
DECLARE
    palette bytea := decode(repeat('123456', 256), 'hex');
    other_palette bytea := decode(repeat('aabbcc', 256), 'hex');
    old_patch bytea := '\x01000100000000000c0000000001001100ff';
    sprite_patch bytea := '\x02000200feff03001000000017000000000200000900ff0101000500ff';
    replacement_patch bytea := '\x010001000700ffff0c0000000001001600ff';
    archive bytea;
    tested_level bigint;
    empty_level bigint;
    test_game bigint;
    frame bytea;
    observed record;
BEGIN
    INSERT INTO doom.levels (name) VALUES ('sprite import') RETURNING level_id INTO tested_level;
    INSERT INTO doom.levels (name) VALUES ('failed sprite import') RETURNING level_id INTO empty_level;

    archive := pg_temp.sprite_archive(
        ARRAY['PLAYPAL', 'TOKEN', 'SS_START', 'token', 'TOKEN', 'SS_END', 'TOKEN', 'IGNORED'],
        ARRAY[palette || other_palette, old_patch, '\x', old_patch, sprite_patch, '\x', old_patch, '\x00']);
    PERFORM doom.import_wad_sprites(tested_level, archive, ARRAY['token', 'TOKEN']);

    SELECT width, height, left_offset, top_offset, pixels, coverage INTO observed
    FROM doom.level_materials WHERE level_id = tested_level AND surface_kind = 'sprite' AND name = 'TOKEN';
    IF ROW(observed.width, observed.height, observed.left_offset, observed.top_offset, observed.pixels, observed.coverage)
        IS DISTINCT FROM ROW(2, 2, -2, 3, '\x00090005'::bytea, '\xffff00ff'::bytea)
        OR (SELECT count(*) FROM doom.level_materials WHERE level_id = tested_level) <> 1
        OR (SELECT lp.palette FROM doom.level_palettes AS lp WHERE level_id = tested_level) IS DISTINCT FROM palette
    THEN
        RAISE EXCEPTION 'sprite selection, pivot, coverage or initial palette was incorrect: %', observed;
    END IF;

    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height, light_level)
    VALUES (tested_level, 0, 0, 128, 255);
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id, wall_color)
    VALUES (tested_level, 0, 16, 16, 16, -16, 0, 1056816);
    INSERT INTO doom.actor_types (kind, default_health, radius, sprite_material)
    VALUES ('wad sprite specimen', 1, 0, 'token');
    test_game := doom.start_game(tested_level, 0, 0, 0);
    INSERT INTO doom.actors (game_id, sector_id, kind, x, y, z)
    VALUES (test_game, 0, 'wad sprite specimen', 8, 0, 39);
    frame := doom.render(test_game, 16, 3);
    IF substring(frame FROM 31 FOR 3) IS DISTINCT FROM '\x123456'::bytea
        OR substring(frame FROM 34 FOR 3) IS DISTINCT FROM '\x102030'::bytea
        OR substring(frame FROM 82 FOR 3) IS DISTINCT FROM '\x123456'::bytea
    THEN
        RAISE EXCEPTION 'imported sprite pivot, opaque index zero or coverage hole did not reach the frame';
    END IF;

    INSERT INTO doom.level_materials (level_id, surface_kind, name, width, height, pixels, coverage)
    VALUES (tested_level, 'wall', 'TOKEN', 1, 1, '\x19', '\xff');
    PERFORM doom.import_wad_sprites(tested_level,
        pg_temp.sprite_archive(ARRAY['PLAYPAL', 'OTHER'], ARRAY[other_palette, old_patch]), ARRAY['OTHER']);
    PERFORM doom.import_wad_sprites(tested_level,
        pg_temp.sprite_archive(ARRAY['TOKEN', 'token'], ARRAY[old_patch, replacement_patch]), ARRAY['TOKEN']);

    SELECT width, height, left_offset, top_offset, pixels, coverage INTO observed
    FROM doom.level_materials WHERE level_id = tested_level AND surface_kind = 'sprite' AND name = 'TOKEN';
    IF ROW(observed.width, observed.height, observed.left_offset, observed.top_offset, observed.pixels, observed.coverage)
        IS DISTINCT FROM ROW(1, 1, 7, -1, '\x16'::bytea, '\xff'::bytea)
        OR (SELECT lp.palette FROM doom.level_palettes AS lp WHERE level_id = tested_level) IS DISTINCT FROM palette
        OR (SELECT pixels FROM doom.level_materials WHERE level_id = tested_level
            AND surface_kind = 'sprite' AND name = 'OTHER') IS DISTINCT FROM '\x11'::bytea
        OR (SELECT pixels FROM doom.level_materials WHERE level_id = tested_level
            AND surface_kind = 'wall' AND name = 'TOKEN') IS DISTINCT FROM '\x19'::bytea
    THEN
        RAISE EXCEPTION 'sprite upsert did not isolate the selected sprite and preserve the palette: %', observed;
    END IF;

    BEGIN
        PERFORM doom.import_wad_sprites(empty_level,
            pg_temp.sprite_archive(ARRAY['ABLE'], ARRAY[old_patch]), ARRAY['ABLE']);
        RAISE EXCEPTION 'initialized a level from a palette-free sprite archive';
    EXCEPTION WHEN invalid_parameter_value THEN
        NULL;
    END;
    BEGIN
        PERFORM doom.import_wad_sprites(empty_level, pg_temp.sprite_archive(
            ARRAY['PLAYPAL', 'ABLE', 'BROKEN'], ARRAY[palette, old_patch, '\x00']), ARRAY['ABLE', 'BROKEN']);
        RAISE EXCEPTION 'accepted a broken selected sprite';
    EXCEPTION WHEN invalid_parameter_value THEN
        NULL;
    END;
    IF EXISTS (SELECT FROM doom.level_palettes WHERE level_id = empty_level)
        OR EXISTS (SELECT FROM doom.level_materials WHERE level_id = empty_level)
    THEN
        RAISE EXCEPTION 'failed sprite import left partial resources';
    END IF;

    BEGIN
        PERFORM doom.import_wad_sprites(tested_level, pg_temp.sprite_archive(
            ARRAY['TOKEN'], ARRAY[old_patch]), ARRAY['TOKEN', 'Z_MISS']);
        RAISE EXCEPTION 'accepted a missing selected sprite';
    EXCEPTION WHEN invalid_parameter_value THEN
        NULL;
    END;
    IF (SELECT pixels FROM doom.level_materials WHERE level_id = tested_level
            AND surface_kind = 'sprite' AND name = 'TOKEN') IS DISTINCT FROM '\x16'::bytea
    THEN
        RAISE EXCEPTION 'failed sprite replacement overwrote the existing sprite';
    END IF;

    BEGIN
        PERFORM doom.import_wad_sprites(tested_level, archive, ARRAY[NULL, 'TOKEN']);
        RAISE EXCEPTION 'accepted a null sprite name';
    EXCEPTION WHEN invalid_parameter_value THEN
        NULL;
    END;
    BEGIN
        PERFORM doom.import_wad_sprites(tested_level, archive, ARRAY['TOOLONGXX']);
        RAISE EXCEPTION 'accepted a sprite name longer than a directory name';
    EXCEPTION WHEN invalid_parameter_value THEN
        NULL;
    END;

    PERFORM doom.import_wad_materials(tested_level,
        pg_temp.sprite_archive(ARRAY['PLAYPAL'], ARRAY[other_palette]));
    IF (SELECT count(*) FROM doom.level_materials WHERE level_id = tested_level AND surface_kind = 'sprite') <> 2
        OR EXISTS (SELECT FROM doom.level_materials WHERE level_id = tested_level AND surface_kind = 'wall')
    THEN
        RAISE EXCEPTION 'surface reimport did not preserve imported sprites';
    END IF;
END;
$$;

ROLLBACK;
