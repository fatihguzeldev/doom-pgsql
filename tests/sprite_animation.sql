\set ON_ERROR_STOP on
BEGIN;

CREATE FUNCTION pg_temp.expect_animation_frame(p_game bigint, p_color bytea, p_case text)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    rgb bytea := doom.render(p_game, 1, 1);
    packet bytea := doom.render_spans(p_game, 1, 1);
BEGIN
    IF rgb IS DISTINCT FROM p_color OR packet IS DISTINCT FROM '\x00000000'::bytea || p_color THEN
        RAISE EXCEPTION '%: expected %, got RGB % and packet %',
            p_case, encode(p_color, 'hex'), encode(rgb, 'hex'), encode(packet, 'hex');
    END IF;
END;
$$;

CREATE FUNCTION pg_temp.expect_animation_clock(p_game bigint, p_actor bigint, p_tick bigint, p_start bigint)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT FROM doom.games AS game
        JOIN doom.actors AS actor USING (game_id)
        WHERE game.game_id = p_game AND actor.actor_id = p_actor
            AND game.tick_number = p_tick AND actor.animation_start_tick = p_start)
    THEN
        RAISE EXCEPTION 'game % actor % expected tick % and animation start %', p_game, p_actor, p_tick, p_start;
    END IF;
END;
$$;

DO $$
DECLARE
    fixture_level bigint;
    batched_game bigint;
    sequential_game bigint;
    specimen bigint;
    marker tid;
    frame_a constant bytea := '\xa02010';
    frame_b constant bytea := '\x20a010';
    static_alive constant bytea := '\x103090';
    first_dead constant bytea := '\xd08040';
    final_dead constant bytea := '\x6030c0';
    static_dead constant bytea := '\x1040d0';
BEGIN
    INSERT INTO doom.levels (name) VALUES ('Clocked sprite fixture') RETURNING level_id INTO fixture_level;
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height, light_level)
    VALUES (fixture_level, 0, 0, 128, 255);
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id, wall_color)
    VALUES (fixture_level, 0, 16, 16, 16, -16, 0, x'112233'::integer);

    INSERT INTO doom.level_palettes (level_id, palette)
    VALUES (fixture_level, frame_a || frame_b || static_alive || first_dead || final_dead || static_dead
        || decode(repeat('00', 750), 'hex'));
    -- The only camera ray crosses the center of every solid test sprite.
    INSERT INTO doom.level_materials
        (level_id, surface_kind, name, width, height, left_offset, top_offset, pixels, coverage)
    SELECT fixture_level, 'sprite', name, 2, 2, 1, 7, decode(repeat(texel, 4), 'hex'), '\xffffffff'::bytea
    FROM (VALUES ('LIV_A', '00'), ('LIV_B', '01'), ('STILL_A', '02'),
                 ('DEAD_A', '03'), ('DEAD_B', '04'), ('STILL_D', '05')) AS materials(name, texel);

    INSERT INTO doom.actor_types (kind, default_health, radius, height, color, sprite_material,
        dead_sprite_material, sprite_frames, dead_sprite_frames, sprite_frame_ticks, dead_sprite_frame_ticks)
    VALUES ('clocked-sprite-fixture', 5, 8, 80, x'303060'::integer, 'STILL_A', 'STILL_D',
        '[0:2]={liv_a,MISSING,LIV_B}', '[4:5]={DEAD_A,DEAD_B}', 2, 3);

    batched_game := doom.start_game(fixture_level, 0, 0, 0);
    sequential_game := doom.start_game(fixture_level, 0, 0, 0);
    PERFORM doom.tick(batched_game, p_ticks => 7);
    PERFORM doom.tick(sequential_game, p_ticks => 7);
    INSERT INTO doom.actors (game_id, sector_id, kind, x, y, z)
    VALUES (batched_game, 0, 'clocked-sprite-fixture', 8, 0, 35)
    RETURNING actor_id, ctid INTO specimen, marker;
    INSERT INTO doom.actors (game_id, sector_id, kind, x, y, z)
    VALUES (sequential_game, 0, 'clocked-sprite-fixture', 8, 0, 35);

    PERFORM pg_temp.expect_animation_frame(batched_game, frame_a, 'spawn starts at the first frame of a zero-based clip');
    PERFORM pg_temp.expect_animation_frame(batched_game, frame_a, 'repeated rendering uses the same clock');
    PERFORM pg_temp.expect_animation_clock(batched_game, specimen, 7, 7);
    IF (SELECT ctid FROM doom.actors WHERE game_id = batched_game AND actor_id = specimen) IS DISTINCT FROM marker THEN
        RAISE EXCEPTION 'rendering must leave the actor row untouched';
    END IF;

    PERFORM doom.tick(batched_game);
    PERFORM pg_temp.expect_animation_frame(batched_game, frame_a, 'a frame lasts for its full tick duration');
    IF doom.step(batched_game, 1, 1) IS DISTINCT FROM static_alive THEN
        RAISE EXCEPTION 'step must render the post-tick sprite and use the living static fallback for a missing frame';
    END IF;
    PERFORM pg_temp.expect_animation_clock(batched_game, specimen, 9, 7);
    UPDATE doom.actors SET health = 1 WHERE game_id = batched_game AND actor_id = specimen;
    PERFORM pg_temp.expect_animation_frame(batched_game, static_alive, 'partial damage keeps the current phase');
    UPDATE doom.actor_types SET sprite_material = NULL WHERE kind = 'clocked-sprite-fixture';
    PERFORM pg_temp.expect_animation_frame(batched_game, '\x303060', 'missing live frame and static sprite use the ellipse');
    UPDATE doom.actor_types SET sprite_material = 'STILL_A' WHERE kind = 'clocked-sprite-fixture';

    PERFORM doom.tick(batched_game, p_ticks => 2);
    FOR i IN 1..4 LOOP
        PERFORM doom.tick(sequential_game);
    END LOOP;
    PERFORM pg_temp.expect_animation_clock(batched_game, specimen, 11, 7);
    PERFORM pg_temp.expect_animation_frame(batched_game, frame_b, 'the clip reaches its third frame');
    PERFORM pg_temp.expect_animation_frame(sequential_game, frame_b, 'sequential and batched ticks select the same frame');
    PERFORM doom.tick(batched_game, p_ticks => 2);
    PERFORM pg_temp.expect_animation_frame(batched_game, frame_a, 'the live clip loops');

    UPDATE doom.actors SET health = 0 WHERE game_id = batched_game AND actor_id = specimen;
    PERFORM pg_temp.expect_animation_clock(batched_game, specimen, 13, 13);
    PERFORM pg_temp.expect_animation_frame(batched_game, first_dead, 'the death clip starts at its first frame');
    PERFORM doom.tick(batched_game, p_ticks => 2);
    UPDATE doom.actors SET health = -6 WHERE game_id = batched_game AND actor_id = specimen;
    PERFORM pg_temp.expect_animation_clock(batched_game, specimen, 15, 13);
    PERFORM pg_temp.expect_animation_frame(batched_game, first_dead, 'a second dead health edit keeps the death phase');
    IF doom.step_spans(batched_game, 1, 1) IS DISTINCT FROM '\x00000000'::bytea || final_dead THEN
        RAISE EXCEPTION 'compact step must use the final death frame at its first tick';
    END IF;
    PERFORM doom.tick(batched_game, p_ticks => 9);
    PERFORM pg_temp.expect_animation_frame(batched_game, final_dead, 'the death clip holds its final frame');
    UPDATE doom.actor_types SET dead_sprite_frames = '[4:5]={DEAD_A,MISSING}' WHERE kind = 'clocked-sprite-fixture';
    PERFORM pg_temp.expect_animation_frame(batched_game, static_dead, 'a missing final frame uses the dead static sprite');
    UPDATE doom.actor_types SET dead_sprite_material = NULL WHERE kind = 'clocked-sprite-fixture';
    PERFORM pg_temp.expect_animation_frame(batched_game, '\x202040', 'missing dead sprites use the shaded ellipse');

    UPDATE doom.actors SET health = 5 WHERE game_id = batched_game AND actor_id = specimen;
    PERFORM pg_temp.expect_animation_clock(batched_game, specimen, 25, 25);
    PERFORM pg_temp.expect_animation_frame(batched_game, frame_a, 'revival restarts the live clip');
    PERFORM doom.tick(batched_game, p_ticks => 4);
    PERFORM pg_temp.expect_animation_frame(batched_game, frame_b, 'the revived clip uses its new clock');
    UPDATE doom.actors SET animation_start_tick = 100 WHERE game_id = batched_game AND actor_id = specimen;
    PERFORM pg_temp.expect_animation_frame(batched_game, frame_a, 'a future anchor selects age zero');
END;
$$;

ROLLBACK;
