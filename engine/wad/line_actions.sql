CREATE FUNCTION doom._bind_wad_actions(p_level_id bigint)
RETURNS void
LANGUAGE plpgsql STRICT
AS $$
BEGIN
    INSERT INTO doom.line_actions (level_id, line_id, activation, effect, once_only,
                                   key_kind, units_per_tick, delay_ticks)
    SELECT raw.level_id, raw.line_id, rule.activation, rule.effect, rule.once_only,
           rule.key_kind, rule.units_per_tick, rule.delay_ticks
    FROM doom.wad_line_actions AS raw
    JOIN (VALUES
        (1,   'use',   'ceiling', false, NULL,     2, 150),
        (2,   'cross', 'ceiling', true,  NULL,     2,   0),
        (3,   'cross', 'ceiling', true,  NULL,     2,   0),
        (4,   'cross', 'ceiling', true,  NULL,     2, 150),
        (5,   'cross', 'floor',   true,  NULL,     1,   0),
        (7,   'use',   'floor',   true,  NULL,     1,   0),
        (8,   'cross', 'floor',   true,  NULL,     1,   0),
        (9,   'use',   'floor',   true,  NULL,     1,   0),
        (10,  'cross', 'floor',   true,  NULL,     4, 105),
        (11,  'use',   'normal',  true,  NULL,     1,   0),
        (16,  'cross', 'ceiling', true,  NULL,     2, 1050),
        (18,  'use',   'floor',   true,  NULL,     1,   0),
        (20,  'use',   'floor',   true,  NULL,     1,   0),
        (21,  'use',   'floor',   true,  NULL,     4, 105),
        (22,  'cross', 'floor',   true,  NULL,     1,   0),
        (23,  'use',   'floor',   true,  NULL,     1,   0),
        (26,  'use',   'ceiling', false, 'blue',   2, 150),
        (27,  'use',   'ceiling', false, 'yellow', 2, 150),
        (28,  'use',   'ceiling', false, 'red',    2, 150),
        (29,  'use',   'ceiling', true,  NULL,     2, 150),
        (31,  'use',   'ceiling', true,  NULL,     2,   0),
        (32,  'use',   'ceiling', true,  'blue',   2,   0),
        (33,  'use',   'ceiling', true,  'red',    2,   0),
        (34,  'use',   'ceiling', true,  'yellow', 2,   0),
        (36,  'cross', 'floor',   true,  NULL,     4,   0),
        (39,  'cross', 'teleport',true,  NULL,     1,   0),
        (42,  'use',   'ceiling', false, NULL,     2,   0),
        (46,  'shoot', 'ceiling', false, NULL,     2,   0),
        (50,  'use',   'ceiling', true,  NULL,     2,   0),
        (51,  'use',   'secret',  true,  NULL,     1,   0),
        (52,  'cross', 'normal',  true,  NULL,     1,   0),
        (61,  'use',   'ceiling', false, NULL,     2,   0),
        (62,  'use',   'floor',   false, NULL,     4, 105),
        (63,  'use',   'ceiling', false, NULL,     2, 150),
        (70,  'use',   'floor',   false, NULL,     4,   0),
        (75,  'cross', 'ceiling', false, NULL,     2,   0),
        (76,  'cross', 'ceiling', false, NULL,     2, 1050),
        (82,  'cross', 'floor',   false, NULL,     1,   0),
        (86,  'cross', 'ceiling', false, NULL,     2,   0),
        (88,  'cross', 'floor',   false, NULL,     4, 105),
        (90,  'cross', 'ceiling', false, NULL,     2, 150),
        (91,  'cross', 'floor',   false, NULL,     1,   0),
        (97,  'cross', 'teleport',false, NULL,     1,   0),
        (98,  'cross', 'floor',   false, NULL,     4,   0),
        (103, 'use',   'ceiling', true,  NULL,     2,   0),
        (117, 'use',   'ceiling', false, NULL,     8, 150),
        (118, 'use',   'ceiling', true,  NULL,     8,   0),
        (124, 'cross', 'secret',  true,  NULL,     1,   0)
    ) AS rule(special, activation, effect, once_only, key_kind, units_per_tick, delay_ticks)
      ON rule.special = raw.special
    WHERE raw.level_id = p_level_id
    ON CONFLICT (level_id, line_id) DO NOTHING;

    WITH RECURSIVE scoped AS MATERIALIZED (
        SELECT action.level_id, action.line_id, action.effect, action.delay_ticks,
               raw.special, raw.tag, line.back_sector_id
        FROM doom.line_actions AS action
        JOIN doom.wad_line_actions AS raw USING (level_id, line_id)
        JOIN doom.lines AS line USING (level_id, line_id)
        WHERE action.level_id = p_level_id AND action.effect IN ('ceiling', 'floor')
    ), candidates AS MATERIALIZED (
        SELECT action.*, target.sector_id, target.floor_height, target.ceiling_height, target.floor_material
        FROM scoped AS action
        JOIN LATERAL (
            SELECT sector.* FROM doom.sectors AS sector
            WHERE action.special IN (1, 26, 27, 28, 31, 32, 33, 34, 117, 118)
              AND sector.level_id = action.level_id AND sector.sector_id = action.back_sector_id
            UNION ALL
            SELECT sector.* FROM doom.wad_sector_properties AS tagged
            JOIN doom.sectors AS sector USING (level_id, sector_id)
            WHERE action.special NOT IN (1, 26, 27, 28, 31, 32, 33, 34, 117, 118)
              AND tagged.level_id = action.level_id AND tagged.tag = action.tag AND tagged.tag <> 0
        ) AS target ON true
    ), neighbors AS MATERIALIZED (
        SELECT edge.line_id, edge.front_sector_id AS origin, edge.back_sector_id AS sector_id,
               sector.floor_height, sector.ceiling_height, sector.floor_material
        FROM doom.lines AS edge
        JOIN doom.sectors AS sector ON sector.level_id = edge.level_id AND sector.sector_id = edge.back_sector_id
        WHERE edge.level_id = p_level_id AND edge.front_sector_id <> edge.back_sector_id
        UNION ALL
        SELECT edge.line_id, edge.back_sector_id, edge.front_sector_id,
               sector.floor_height, sector.ceiling_height, sector.floor_material
        FROM doom.lines AS edge
        JOIN doom.sectors AS sector ON sector.level_id = edge.level_id AND sector.sector_id = edge.front_sector_id
        WHERE edge.level_id = p_level_id AND edge.front_sector_id <> edge.back_sector_id
    ), stairs (line_id, sector_id, height, visited, material) AS (
        SELECT line_id, sector_id, floor_height + 8, ARRAY[sector_id], floor_material
        FROM candidates WHERE special IN (7, 8)
        UNION ALL
        SELECT stairs.line_id, next.sector_id, stairs.height + 8, stairs.visited || next.sector_id, stairs.material
        FROM stairs
        CROSS JOIN LATERAL (
            SELECT edge.back_sector_id AS sector_id
            FROM doom.lines AS edge
            JOIN doom.sectors AS sector ON sector.level_id = edge.level_id AND sector.sector_id = edge.back_sector_id
            WHERE edge.level_id = p_level_id AND edge.front_sector_id = stairs.sector_id
              AND sector.floor_material IS NOT DISTINCT FROM stairs.material
              AND sector.sector_id <> ALL(stairs.visited)
            ORDER BY edge.line_id LIMIT 1
        ) AS next
    ), raised AS (
        SELECT candidate.line_id, candidate.sector_id,
               CASE
                   WHEN candidate.special IN (3, 16, 42, 50, 75, 76) THEN candidate.floor_height
                   WHEN candidate.effect = 'ceiling' THEN greatest(candidate.ceiling_height, around.ceiling_height - 4)
                   WHEN candidate.special IN (5, 91) THEN greatest(candidate.floor_height,
                       least(candidate.ceiling_height, around.ceiling_height))
                   WHEN candidate.special IN (18, 20, 22) THEN least(candidate.ceiling_height, around.next_floor)
                   WHEN candidate.special IN (36, 70, 98) THEN least(candidate.floor_height, around.highest_floor + 8)
                   ELSE least(candidate.floor_height, around.lowest_floor)
               END AS height,
               CASE WHEN candidate.delay_ticks = 0 THEN NULL
                    WHEN candidate.special IN (16, 76) OR candidate.effect = 'floor'
                        THEN CASE WHEN candidate.effect = 'floor' THEN candidate.floor_height ELSE candidate.ceiling_height END
                    ELSE candidate.floor_height END AS return_height
        FROM candidates AS candidate
        CROSS JOIN LATERAL (
            SELECT min(floor_height) AS lowest_floor, max(floor_height) AS highest_floor,
                   min(floor_height) FILTER (WHERE floor_height > candidate.floor_height) AS next_floor,
                   min(ceiling_height) AS ceiling_height
            FROM neighbors WHERE origin = candidate.sector_id
        ) AS around
        WHERE candidate.special NOT IN (7, 8, 9)
    ), rings AS (
        SELECT candidate.line_id, candidate.sector_id, ring.sector_id AS ring_id, outside.floor_height
        FROM candidates AS candidate
        CROSS JOIN LATERAL (
            SELECT sector_id FROM neighbors WHERE origin = candidate.sector_id ORDER BY line_id LIMIT 1
        ) AS ring
        CROSS JOIN LATERAL (
            SELECT floor_height FROM neighbors WHERE origin = ring.sector_id AND sector_id <> candidate.sector_id
            ORDER BY line_id LIMIT 1
        ) AS outside
        WHERE candidate.special = 9
    ), targets AS (
        SELECT * FROM raised
        UNION ALL SELECT line_id, sector_id, height, NULL FROM stairs
        UNION ALL SELECT line_id, sector_id, floor_height, NULL FROM rings
        UNION ALL SELECT line_id, ring_id, floor_height, NULL FROM rings
    )
    INSERT INTO doom.line_action_targets (level_id, line_id, sector_id, height, return_height)
    SELECT DISTINCT ON (target.line_id, target.sector_id) p_level_id, target.line_id, target.sector_id,
           target.height, target.return_height
    FROM targets AS target
    WHERE target.height IS NOT NULL
    ORDER BY target.line_id, target.sector_id, target.height
    ON CONFLICT (level_id, line_id, sector_id) DO NOTHING;

    DELETE FROM doom.line_actions AS action
    WHERE action.level_id = p_level_id AND action.effect IN ('ceiling', 'floor')
      AND NOT EXISTS (SELECT FROM doom.line_action_targets AS target
                      WHERE (target.level_id, target.line_id) = (action.level_id, action.line_id));
END;
$$;
