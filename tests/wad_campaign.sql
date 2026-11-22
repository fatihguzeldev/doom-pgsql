BEGIN;
SET LOCAL plpgsql.check_asserts = on;

CREATE FUNCTION pg_temp.campaign_le32(p_value integer)
RETURNS bytea LANGUAGE sql IMMUTABLE STRICT
RETURN set_byte(set_byte(set_byte(set_byte('\x00000000'::bytea, 0, p_value & 255),
    1, (p_value >> 8) & 255), 2, (p_value >> 16) & 255), 3, (p_value >> 24) & 255);

CREATE FUNCTION pg_temp.campaign_wad(p_names text[], p_lumps bytea[])
RETURNS bytea LANGUAGE sql IMMUTABLE STRICT
RETURN (
    WITH entries AS (
        SELECT name, data, entry_index, octet_length(data) AS size,
               12 + coalesce(sum(octet_length(data)) OVER (
                   ORDER BY entry_index ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0)::integer AS position
        FROM unnest(p_names, p_lumps) WITH ORDINALITY AS entry(name, data, entry_index)
    )
    SELECT '\x50574144'::bytea || pg_temp.campaign_le32(count(*)::integer)
        || pg_temp.campaign_le32(12 + sum(size)::integer)
        || string_agg(data, '\x'::bytea ORDER BY entry_index)
        || string_agg(pg_temp.campaign_le32(position) || pg_temp.campaign_le32(size)
            || convert_to(name, 'UTF8') || decode(repeat('00', 8 - length(name)), 'hex'),
            '\x'::bytea ORDER BY entry_index)
    FROM entries
);

DO $$
DECLARE
    names text[] := ARRAY['PLAYPAL'];
    payloads bytea[] := ARRAY[decode(repeat('00', 768), 'hex')];
    map_name text;
    linedefs bytea;
    campaign bigint;
    first_game bigint;
    side_game bigint;
    final_game bigint;
    level_count bigint;
    advanced record;
BEGIN
    -- Deliberately write the directory out of campaign order.
    FOREACH map_name IN ARRAY ARRAY['E1M9', 'E1M2', 'E1M1'] LOOP
        names := names || ARRAY[map_name, 'THINGS', 'LINEDEFS', 'SIDEDEFS', 'VERTEXES',
                               'SEGS', 'SSECTORS', 'NODES', 'SECTORS', 'REJECT', 'BLOCKMAP'];
        linedefs := decode('0000 0100 0100 0000 0000 0000 ffff'
            || '0100 0200 0100 0000 0000 0000 ffff'
            || '0200 0300 0100 ' || CASE WHEN map_name = 'E1M1' THEN '3300' ELSE '0b00' END
            || ' 0000 0000 ffff'
            || '0300 0000 0100 0000 0000 0000 ffff', 'hex');
        payloads := payloads || ARRAY['\x'::bytea, '\x20002000000001000700', linedefs,
                decode(repeat('00', 30), 'hex'), '\x00000000000040004000400040000000',
                '\x', '\x', '\x', decode('00006000' || repeat('00', 16) || 'a00000000000', 'hex'), '\x', '\x'];
    END LOOP;

    campaign := doom.import_wad_campaign(pg_temp.campaign_wad(names, payloads));
    ASSERT (SELECT count(*) FROM doom.wad_campaign_levels WHERE campaign_id = campaign) = 3,
        'one import creates each directory map once';
    first_game := doom.start_wad_campaign(campaign, 2);
    ASSERT (SELECT name FROM doom.levels JOIN doom.games USING (level_id) WHERE game_id = first_game) = 'E1M1';
    ASSERT doom.advance_wad_campaign(first_game) IS NULL, 'a live map cannot advance';

    UPDATE doom.actors SET health = 70 WHERE game_id = first_game AND kind = 'player';
    INSERT INTO doom.game_keys (game_id, key_kind) VALUES (first_game, 'red');
    PERFORM doom.tick(first_game, p_use => true);
    ASSERT (SELECT exit_kind FROM doom.games WHERE game_id = first_game) = 'secret',
        'the imported secret switch completes through the normal use input';

    side_game := doom.advance_wad_campaign(first_game);
    ASSERT (SELECT name FROM doom.levels JOIN doom.games USING (level_id) WHERE game_id = side_game) = 'E1M9';
    ASSERT doom.advance_wad_campaign(first_game) = side_game, 'retries do not start a duplicate next game';
    ASSERT (SELECT health FROM doom.actors WHERE game_id = side_game AND kind = 'player') = 70
       AND (SELECT skill FROM doom.wad_campaign_games WHERE game_id = side_game) = 2
       AND NOT EXISTS (SELECT FROM doom.game_keys WHERE game_id = side_game),
        'campaign progression carries health and skill while refreshing map keys';

    SELECT * INTO STRICT advanced FROM doom.step_wad_campaign(side_game, 7, 5,
        ARRAY[ROW(0, 0, 0, 1, true, false)::doom.input_command]);
    final_game := advanced.game_id;
    ASSERT (SELECT name FROM doom.levels JOIN doom.games USING (level_id) WHERE game_id = final_game) = 'E1M2',
        'an ordinary exit from a secret map resumes the original route';
    ASSERT NOT advanced.campaign_finished AND advanced.frame = doom.render_compact(final_game, 7, 5),
        'the campaign step renders its newly active map';
    SELECT * INTO STRICT advanced FROM doom.step_wad_campaign(final_game, 7, 5,
        ARRAY[ROW(0, 0, 0, 1, true, false)::doom.input_command]);
    ASSERT advanced.campaign_finished AND advanced.game_id = final_game
       AND doom.advance_wad_campaign(final_game) IS NULL
       AND (SELECT exit_kind FROM doom.games WHERE game_id = final_game) = 'normal',
        'the final map finishes the campaign';

    SELECT count(*) INTO level_count FROM doom.levels;
    -- Corrupt the last map in load order so a previous import has already run.
    names[3] := 'BADTHING';
    BEGIN
        PERFORM doom.import_wad_campaign(pg_temp.campaign_wad(names, payloads));
        RAISE EXCEPTION 'campaign accepted malformed map';
    EXCEPTION WHEN invalid_parameter_value THEN
        NULL;
    END;
    ASSERT (SELECT count(*) FROM doom.levels) = level_count, 'a failed campaign import leaves no partial maps';
END;
$$;

ROLLBACK;
