BEGIN;
SET LOCAL plpgsql.check_asserts = on;

DO $$
DECLARE
    level_id bigint;
    fixture_game bigint;
    leader_id bigint;
    follower_id bigint;
BEGIN
    INSERT INTO doom.levels AS level (name) VALUES ('ordered pursuit fixture') RETURNING level.level_id INTO level_id;
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height)
    VALUES (level_id, 0, 0, 128);
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id)
    VALUES (level_id, 0, -100, -100, -100, 100, 0),
           (level_id, 1, -100, 100, 200, 100, 0),
           (level_id, 2, 200, 100, 200, -100, 0),
           (level_id, 3, 200, -100, -100, -100, 0);
    INSERT INTO doom.actor_types (kind, default_health, radius)
    VALUES ('pursuit batch leader', 30, 10), ('pursuit batch follower', 30, 8);
    INSERT INTO doom.actor_pursuits (kind, sight_range, move_distance, interval_ticks)
    VALUES ('pursuit batch leader', 128, 40, 1), ('pursuit batch follower', 128, 4, 1);

    fixture_game := doom.start_game(level_id, 0, 0, 0);
    INSERT INTO doom.actors (game_id, sector_id, kind, x, y)
    VALUES (fixture_game, 0, 'pursuit batch leader', 50, 20) RETURNING actor_id INTO leader_id;
    INSERT INTO doom.actors (game_id, sector_id, kind, x, y)
    VALUES (fixture_game, 0, 'pursuit batch follower', 60, 0) RETURNING actor_id INTO follower_id;

    PERFORM doom.tick(fixture_game);
    ASSERT (SELECT y < 10 FROM doom.actors AS actor WHERE actor.actor_id = leader_id),
        'the first pursuer moves between the second pursuer and the player';
    ASSERT (SELECT x = 60 FROM doom.actors AS actor WHERE actor.actor_id = follower_id),
        'the second pursuer sees the position resolved earlier in the same tick';

    UPDATE doom.actors SET health = 0 WHERE actor_id = leader_id;
    PERFORM doom.tick(fixture_game);
    ASSERT (SELECT x = 56 FROM doom.actors AS actor WHERE actor.actor_id = follower_id),
        'a SQL state edit is included in the next pursuit working set';

    UPDATE doom.actor_types SET attack_range = 80, attack_damage = 7
    WHERE kind = 'pursuit batch leader';
    UPDATE doom.actors SET x = 0, y = 36, health = 30 WHERE actor_id = leader_id;
    PERFORM doom.tick(fixture_game);
    ASSERT (SELECT health = 93 FROM doom.actors AS player
            WHERE player.game_id = fixture_game AND player.kind = 'player'),
        'damage resolved by the first pursuer is committed with the tick';
    ASSERT (SELECT x = 52 FROM doom.actors AS actor WHERE actor.actor_id = follower_id),
        'the remaining pursuer still acts after damage is resolved';
END;
$$;

ROLLBACK;
