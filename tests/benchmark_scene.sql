\set ON_ERROR_STOP on
\set QUIET on
\if :{?rooms}
\else
    \set rooms 16
\endif
\if :{?actors}
\else
    \set actors 0
\endif
\if :{?textured}
\else
    \set textured false
\endif

BEGIN;
INSERT INTO doom.levels (name) VALUES ('benchmark corridor') RETURNING level_id \gset

INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height, light_level)
SELECT :level_id, room, room % 4 * 2, 96 - room % 5 * 4, 252 - room % 12 * 16
FROM generate_series(0, :rooms - 1) AS room;

INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id, back_sector_id)
SELECT :level_id, 0, 0, -48, 0, 48, 0, NULL
UNION ALL
SELECT :level_id, 3 * room + wall.ordinal, wall.x1, wall.y1, wall.x2, wall.y2, room, wall.neighbor
FROM generate_series(0, :rooms - 1) AS room
CROSS JOIN LATERAL (VALUES
    (1, 128 * room, 48, 128 * (room + 1), 48, NULL::integer),
    (2, 128 * (room + 1), -48, 128 * room, -48, NULL::integer),
    (3, 128 * (room + 1), 48, 128 * (room + 1), -48,
        CASE WHEN room < :rooms - 1 THEN room + 1 END)
) AS wall(ordinal, x1, y1, x2, y2, neighbor);

\if :textured
    INSERT INTO doom.level_palettes (level_id, palette)
    SELECT :level_id, string_agg(decode(lpad(to_hex(
        ((entry * 11 % 256) << 16) | ((entry * 7 % 256) << 8) | (entry * 3 % 256)
    ), 6, '0'), 'hex'), ''::bytea ORDER BY entry)
    FROM generate_series(0, 255) AS entry;

    INSERT INTO doom.level_materials (level_id, surface_kind, name, width, height, pixels, coverage)
    SELECT :level_id, material.kind, material.name, 64, 64,
           string_agg(decode(lpad(to_hex((x * 5 + y * 7 + material.color_offset) % 256), 2, '0'), 'hex'),
                      ''::bytea ORDER BY x, y),
           decode(repeat('ff', 4096), 'hex')
    FROM (VALUES ('wall', 'BENCHWL', 1), ('flat', 'BENCHFL', 43)) AS material(kind, name, color_offset)
    CROSS JOIN generate_series(0, 63) AS x
    CROSS JOIN generate_series(0, 63) AS y
    GROUP BY material.kind, material.name;

    UPDATE doom.sectors SET floor_material = 'BENCHFL', ceiling_material = 'BENCHFL'
    WHERE level_id = :level_id;

    INSERT INTO doom.line_surfaces (level_id, line_id, is_back, x_offset, upper_material,
                                    lower_material, middle_material)
    SELECT :level_id, line.line_id, side.is_back, line.line_id % 8, 'BENCHWL', 'BENCHWL', 'BENCHWL'
    FROM doom.lines AS line
    CROSS JOIN (VALUES (false), (true)) AS side(is_back)
    WHERE line.level_id = :level_id AND (NOT side.is_back OR line.back_sector_id IS NOT NULL);
\endif

SELECT doom.start_game(:level_id, 0, 32, 0) AS game_id \gset

INSERT INTO doom.actor_types (kind, default_health, radius, height, color)
SELECT 'benchmark pylon', 20, 7, 38, 14449480
WHERE :actors > 0
ON CONFLICT (kind) DO NOTHING;

INSERT INTO doom.actors (game_id, sector_id, kind, x, y)
SELECT :game_id, (actor_id - 1) % :rooms, 'benchmark pylon',
       ((actor_id - 1) % :rooms) * 128 + 48 + (actor_id * 17) % 64,
       (actor_id * 37) % 71 - 35
FROM generate_series(1, :actors) AS actor(actor_id);

SELECT :game_id;
COMMIT;
