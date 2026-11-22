BEGIN;

CREATE FUNCTION pg_temp.wad_texture_le32(p_value integer)
RETURNS bytea LANGUAGE sql IMMUTABLE STRICT
RETURN decode(lpad(to_hex(p_value & 255), 2, '0')
    || lpad(to_hex((p_value >> 8) & 255), 2, '0')
    || lpad(to_hex((p_value >> 16) & 255), 2, '0')
    || lpad(to_hex((p_value >> 24) & 255), 2, '0'), 'hex');

CREATE FUNCTION pg_temp.wad_texture_archive(p_names text[], p_data bytea[])
RETURNS bytea LANGUAGE sql IMMUTABLE STRICT
RETURN (
    WITH entries AS (
        SELECT label, payload, entry_index, octet_length(payload) AS size,
               12 + coalesce(sum(octet_length(payload)) OVER (
                   ORDER BY entry_index ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0)::integer AS start
        FROM unnest(p_names, p_data) WITH ORDINALITY AS entry(label, payload, entry_index)
    )
    SELECT '\x50574144'::bytea || pg_temp.wad_texture_le32(count(*)::integer)
        || pg_temp.wad_texture_le32(12 + sum(size)::integer)
        || string_agg(payload, '\x'::bytea ORDER BY entry_index)
        || string_agg(pg_temp.wad_texture_le32(start) || pg_temp.wad_texture_le32(size)
             || convert_to(label, 'UTF8') || decode(repeat('00', 8 - length(label)), 'hex'),
             '\x'::bytea ORDER BY entry_index)
    FROM entries
);

CREATE FUNCTION pg_temp.wad_texture_directory_fixture(p_records bytea[])
RETURNS bytea LANGUAGE sql IMMUTABLE STRICT
RETURN (
    WITH entries AS (
        SELECT item, entry_index,
               4 + 4 * cardinality(p_records) + coalesce(sum(octet_length(item)) OVER (
                   ORDER BY entry_index ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0)::integer AS start
        FROM unnest(p_records) WITH ORDINALITY AS entry(item, entry_index)
    )
    SELECT pg_temp.wad_texture_le32(cardinality(p_records))
        || string_agg(pg_temp.wad_texture_le32(start), '\x'::bytea ORDER BY entry_index)
        || string_agg(item, '\x'::bytea ORDER BY entry_index)
    FROM entries
);

DO $$
DECLARE
    pnames bytea := decode('02000000 7062617365000000 70746f7000000000', 'hex');
    base_patch bytea := decode(
        '0300 0400 0200 0800 14000000 1d000000 26000000' ||
        '0004000102030400ff 0004001112131400ff 0004002122232400ff', 'hex');
    top_patch bytea := decode(
        '0300 0300 0000 0000 14000000 1c000000 27000000' ||
        '00030001020300ff 0001005500 0201000000 ff 00030061626300ff', 'hex');
    early_panel bytea := decode(
        '50414e454c000000 00000000 0100 0100 00000000 0100 0000 0000 0000 0000 0000', 'hex');
    final_panel bytea := decode(
        '50414e454c000000 00000000 0200 0300 00000000 0200' ||
        '0000 0000 0000 0000 0000' || 'ffff ffff 0100 0000 0000', 'hex');
    strip_texture bytea := decode(
        '5354524950000000 01000000 0300 0400 00000000 0100 0100 0100 0100 0000 0000', 'hex');
    small_texture bytea := decode(
        '534d414c4c000000 00000000 0100 0100 00000000 0100 0000 0000 0000 0000 0000', 'hex');
    first_catalog bytea := pg_temp.wad_texture_directory_fixture(ARRAY[early_panel, small_texture]);
    second_catalog bytea := pg_temp.wad_texture_directory_fixture(ARRAY[early_panel, strip_texture, final_panel]);
    archive bytea := pg_temp.wad_texture_archive(
        ARRAY['PNAMES', 'TEXTURE1', 'pbase', 'PTOP', 'TEXTURE2', 'ptop'],
        ARRAY[pnames, first_catalog, base_patch, '\x00'::bytea, second_catalog, top_patch]);
    decoded text[];
    invalid record;
BEGIN
    SELECT array_agg(ARRAY[name, width::text, height::text, encode(pixels, 'hex'), encode(coverage, 'hex')]
                     ORDER BY name)
    INTO decoded
    FROM doom.wad_textures(archive, ARRAY['strip', 'PaNeL', 'small', 'PANEL']);
    IF decoded IS DISTINCT FROM ARRAY[
        ['PANEL', '2', '3', '010003626313', 'ffffffffffff'],
        ['SMALL', '1', '1', '01', 'ff'],
        ['STRIP', '3', '4', '000000000001020300550000', '0000000000ffffff00ff00ff']
    ] THEN
        RAISE EXCEPTION 'incorrect indexed composite textures: %', decoded;
    END IF;

    IF (SELECT pixels FROM doom.wad_textures(
            pg_temp.wad_texture_archive(ARRAY['PNAMES', 'TEXTURE1', 'PBASE'],
                                        ARRAY[pnames, first_catalog, base_patch]), ARRAY['PANEL']))
        IS DISTINCT FROM '\x01'::bytea
    THEN
        RAISE EXCEPTION 'TEXTURE2 should be optional';
    END IF;

    FOR invalid IN
        SELECT * FROM (VALUES
            ('missing texture', pnames, first_catalog, 'MISSING'),
            ('blank requested name', pnames, first_catalog, ''),
            ('null requested name', pnames, first_catalog, NULL),
            ('atypically large PNAMES count', '\xffffff7f'::bytea, first_catalog, 'PANEL'),
            ('truncated texture catalog', pnames, substring(first_catalog FOR 7), 'PANEL'),
            ('definition offset in catalog directory', pnames, set_byte(first_catalog, 4, 3), 'PANEL'),
            ('invalid width', pnames, set_byte(first_catalog, 24, 0), 'PANEL'),
            ('patch descriptors overlap next record', pnames, set_byte(first_catalog, 32, 2), 'PANEL'),
            ('patch index is outside PNAMES', pnames, set_byte(first_catalog, 38, 2), 'PANEL'),
            ('named patch is missing', pnames, set_byte(first_catalog, 38, 1), 'PANEL')
        ) AS cases(label, patch_names, catalog, requested_name)
    LOOP
        BEGIN
            PERFORM * FROM doom.wad_textures(
                pg_temp.wad_texture_archive(ARRAY['PNAMES', 'TEXTURE1', 'PBASE'],
                                            ARRAY[invalid.patch_names, invalid.catalog, base_patch]),
                ARRAY[invalid.requested_name]);
            RAISE EXCEPTION 'WAD texture reader accepted %', invalid.label;
        EXCEPTION WHEN invalid_parameter_value THEN
            NULL;
        END;
    END LOOP;
END;
$$;

ROLLBACK;
