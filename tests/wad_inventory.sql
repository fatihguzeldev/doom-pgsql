BEGIN;
SET LOCAL plpgsql.check_asserts = on;

DO $$
DECLARE
    fixture_level bigint;
    fixture_game bigint;
    player doom.actors;
    target_id bigint;
    damaged_health integer;
BEGIN
    INSERT INTO doom.levels (name) VALUES ('equipment fixture') RETURNING level_id INTO fixture_level;
    INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height)
    VALUES (fixture_level, 0, 0, 96);
    INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id)
    VALUES (fixture_level, 0, 224, 48, 224, -48, 0),
           (fixture_level, 1, -32, -48, -32, 48, 0);
    INSERT INTO doom.actor_types (kind, default_health, radius)
    VALUES ('equipment target fixture', 150, 8);
    fixture_game := doom.start_game(fixture_level, 0, 0, 0);
    INSERT INTO doom.actors (game_id, sector_id, kind, x, y)
    VALUES (fixture_game, 0, 'equipment target fixture', 96, 0) RETURNING actor_id INTO target_id;
    SELECT * INTO STRICT player FROM doom.actors WHERE game_id = fixture_game AND kind = 'player';
    INSERT INTO doom.game_inventory (game_id, item_kind, amount)
    VALUES (fixture_game, 'weapon-spread', 1), (fixture_game, 'weapon-melee', 1),
           (fixture_game, 'weapon-burst', 1), (fixture_game, 'energy', 2),
           (fixture_game, 'shells', 2), (fixture_game, 'armor', 2);

    ASSERT doom._fire_actor(player, 0) = 88, 'the projectile stops at the first target body';
    ASSERT (SELECT health FROM doom.actors WHERE game_id = fixture_game AND actor_id = target_id) = 108
        AND (SELECT amount FROM doom.game_inventory WHERE game_id = fixture_game AND item_kind = 'shells') = 1
        AND (SELECT amount FROM doom.game_inventory WHERE game_id = fixture_game AND item_kind = 'energy') = 2,
        'an understocked higher-priority weapon spends nothing and the next loaded weapon fires';

    player.angle := pi();
    ASSERT doom._fire_actor(player, 0) = 288, 'a miss still reports the effective weapon range';
    ASSERT NOT EXISTS (SELECT FROM doom.game_inventory WHERE game_id = fixture_game AND item_kind = 'shells'),
        'a missed shot still spends its ammunition';

    player.angle := 0;
    ASSERT doom._fire_actor(player, 0) = 88;
    ASSERT (SELECT health FROM doom.actors WHERE game_id = fixture_game AND actor_id = target_id) = 88,
        'a distant target outside melee reach uses the stock attack after ammo runs out';

    UPDATE doom.actors SET x = 36 WHERE game_id = fixture_game AND actor_id = target_id;
    ASSERT doom._fire_actor(player, 0) = 28;
    ASSERT (SELECT health FROM doom.actors WHERE game_id = fixture_game AND actor_id = target_id) = 56,
        'an available close-range weapon changes damage without consuming ammo';

    damaged_health := doom._damage_actor(fixture_game, player.actor_id, 9, 0);
    ASSERT damaged_health = 93
        AND NOT EXISTS (SELECT FROM doom.game_inventory WHERE game_id = fixture_game AND item_kind = 'armor'),
        'armor absorbs up to one third of a hit and depletes at zero';
    ASSERT doom._damage_actor(fixture_game, player.actor_id, 9, 0) = 84,
        'incoming damage is unchanged after armor has depleted';
END;
$$;

ROLLBACK;
