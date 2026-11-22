CREATE TABLE doom.wad_weapons (
    item_kind text PRIMARY KEY,
    priority integer NOT NULL UNIQUE,
    attack_range integer NOT NULL CHECK (attack_range > 0),
    attack_damage integer NOT NULL CHECK (attack_damage > 0),
    ammo_kind text,
    ammo_per_shot integer NOT NULL CHECK (
        (ammo_kind IS NULL AND ammo_per_shot = 0) OR (ammo_kind IS NOT NULL AND ammo_per_shot > 0)
    )
);

INSERT INTO doom.wad_weapons (item_kind, priority, attack_range, attack_damage, ammo_kind, ammo_per_shot)
VALUES ('weapon-melee', 10, 56, 32, NULL, 0),
       ('weapon-rapid', 20, 512, 28, 'rounds', 2),
       ('weapon-spread', 30, 288, 42, 'shells', 1),
       ('weapon-energy', 40, 512, 44, 'energy', 2),
       ('weapon-heavy', 50, 448, 64, 'rockets', 1),
       ('weapon-burst', 60, 384, 90, 'energy', 8);

CREATE FUNCTION doom._consume_inventory(
    p_game_id bigint, p_item_kind text, p_amount integer, p_allow_partial boolean DEFAULT false
)
RETURNS integer
LANGUAGE plpgsql STRICT
AS $$
DECLARE
    stock integer;
    spent integer;
BEGIN
    IF p_amount <= 0 THEN
        RETURN 0;
    END IF;

    SELECT amount INTO stock FROM doom.game_inventory
    WHERE game_id = p_game_id AND item_kind = p_item_kind
    FOR NO KEY UPDATE;
    IF NOT FOUND OR (stock < p_amount AND NOT p_allow_partial) THEN
        RETURN 0;
    END IF;

    spent := least(stock, p_amount);
    IF stock = spent THEN
        DELETE FROM doom.game_inventory WHERE game_id = p_game_id AND item_kind = p_item_kind;
    ELSE
        UPDATE doom.game_inventory SET amount = stock - spent
        WHERE game_id = p_game_id AND item_kind = p_item_kind;
    END IF;
    RETURN spent;
END;
$$;

CREATE FUNCTION doom._wad_weapon_attack(p_game_id bigint, p_target_distance double precision)
RETURNS TABLE (reach integer, damage integer)
LANGUAGE plpgsql
AS $$
DECLARE
    weapon doom.wad_weapons;
BEGIN
    FOR weapon IN
        SELECT profile.*
        FROM doom.game_inventory AS held
        JOIN doom.wad_weapons AS profile USING (item_kind)
        WHERE held.game_id = p_game_id
          AND (profile.attack_range >= p_target_distance
               OR (p_target_distance IS NULL AND profile.ammo_kind IS NOT NULL))
        ORDER BY profile.priority DESC
    LOOP
        IF weapon.ammo_kind IS NULL
            OR doom._consume_inventory(p_game_id, weapon.ammo_kind, weapon.ammo_per_shot) = weapon.ammo_per_shot
        THEN
            reach := weapon.attack_range;
            damage := weapon.attack_damage;
            RETURN NEXT;
            RETURN;
        END IF;
    END LOOP;
END;
$$;
