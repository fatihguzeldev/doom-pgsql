#!/bin/sh

# Usage: sh tests/concurrency.sh DATABASE (install the engine in DATABASE first).
set -eu
: "${1:?pass the installed test database name or connection string}"
database=$1
scratch=$(mktemp -d "${TMPDIR:-/tmp}/doom-concurrency.XXXXXXXX")
owner_app=doom-concurrency-owner-$$
tick_app=doom-concurrency-tick-$$
actor_kind=concurrency-fixture-$$
owner_pid=
tick_pid=
level_id=
game_id=

db() {
    PGOPTIONS="${PGOPTIONS:+$PGOPTIONS }-c statement_timeout=10s -c idle_in_transaction_session_timeout=12s" \
        psql -XqAt -v ON_ERROR_STOP=1 -d "$database" "$@"
}

cleanup() {
    status=$?
    trap - EXIT
    exec 3>&-
    for pid in "$owner_pid" "$tick_pid"; do
        if [ -n "$pid" ]; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
    if [ -n "$game_id" ]; then
        db -v game_id="$game_id" -v level_id="$level_id" -v actor_kind="$actor_kind" <<'SQL' || status=1
BEGIN;
DELETE FROM doom.games WHERE game_id = :game_id;
DELETE FROM doom.levels WHERE level_id = :level_id;
DELETE FROM doom.actor_types WHERE kind = :'actor_kind';
COMMIT;
SQL
    fi
    for file in "$scratch/owner.log" "$scratch/tick.log"; do
        if [ -f "$file" ]; then
            if [ "$status" -ne 0 ]; then cat "$file" >&2; fi
            rm "$file"
        fi
    done
    if [ -p "$scratch/owner" ]; then rm "$scratch/owner"; fi
    rmdir "$scratch"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

wait_for_peer() {
    attempt=0
    while [ "$attempt" -lt 150 ]; do
        reached=$(db -v app="$1" -v expected="$2" <<'SQL'
SELECT EXISTS (
    SELECT FROM pg_stat_activity
    WHERE datname = current_database() AND application_name = :'app'
      AND CASE :'expected'
              WHEN 'ready' THEN state = 'idle in transaction' AND query LIKE '%doom_concurrency_ready%'
              WHEN 'advanced' THEN state = 'idle in transaction' AND query LIKE '%doom_concurrency_advanced%'
              WHEN 'blocked' THEN state = 'active' AND wait_event_type = 'Lock'
          END
);
SQL
        )
        if [ "$reached" = t ]; then return 0; fi
        attempt=$((attempt + 1))
        sleep 0.02
    done
    printf '%s did not become %s\n' "$1" "$2" >&2
    return 1
}

start_owner() {
    PGAPPNAME="$owner_app" db <"$scratch/owner" >"$scratch/owner.log" 2>&1 &
    owner_pid=$!
    exec 3>"$scratch/owner"
    printf 'BEGIN;\n%s;\nSELECT 1 AS doom_concurrency_ready;\n' "$1" >&3
    wait_for_peer "$owner_app" ready
}

finish_owner() {
    printf 'COMMIT;\n' >&3
    exec 3>&-
    wait "$owner_pid"
    owner_pid=
}

finish_peers() {
    finish_owner
    wait "$tick_pid"
    tick_pid=
}

assert_player() {
    actual=$(db -c "SELECT g.tick_number, a.health, a.x, a.animation_start_tick
        FROM doom.games AS g JOIN doom.actors AS a USING (game_id)
        WHERE g.game_id = $game_id AND a.kind = 'player'")
    if [ "$actual" != "$1" ]; then
        printf 'expected tick|health|x|animation anchor = %s, observed %s\n' "$1" "$actual" >&2
        return 1
    fi
}

ids=$(db -v actor_kind="$actor_kind" <<'SQL'
BEGIN;
INSERT INTO doom.levels (name) VALUES ('concurrency fixture') RETURNING level_id \gset
INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height)
VALUES (:level_id, 0, 0, 128);
INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id)
VALUES (:level_id, 0, 0, 0, 0, 512, 0),
       (:level_id, 1, 0, 512, 512, 512, 0),
       (:level_id, 2, 512, 512, 512, 0, 0),
       (:level_id, 3, 512, 0, 0, 0, 0);
INSERT INTO doom.actor_types (kind, default_health) VALUES (:'actor_kind', 31);
SELECT doom.start_game(:level_id, 0, 128, 128) AS game_id \gset
COMMIT;
SELECT :level_id, :game_id;
SQL
)
level_id=${ids%%|*}
game_id=${ids#*|}
mkfifo "$scratch/owner"

# The tick must see the committed health edit before moving the player.
start_owner "UPDATE doom.actors SET health = 0 WHERE game_id = $game_id AND kind = 'player'"
PGAPPNAME="$tick_app" db -c "SELECT doom.tick($game_id, 1)" >"$scratch/tick.log" 2>&1 3>&- &
tick_pid=$!
wait_for_peer "$tick_app" blocked
finish_peers
assert_player '1|0|128|0'

# Independent actor edits use the last committed clock while ticks serialize.
db -c "UPDATE doom.actors SET health = 100 WHERE game_id = $game_id AND kind = 'player'"
start_owner "SELECT doom.tick($game_id, 1, 0, 0, 2)"
PGAPPNAME="$tick_app" db -c "SELECT doom.tick($game_id, 1, 0, 0, 3)" >"$scratch/tick.log" 2>&1 3>&- &
tick_pid=$!
wait_for_peer "$tick_app" blocked
observed_actor=$(db -v game_id="$game_id" -v actor_kind="$actor_kind" <<'SQL'
BEGIN;
SET LOCAL lock_timeout = '1s';
INSERT INTO doom.actors (game_id, kind, x, y) VALUES (:game_id, :'actor_kind', 400, 400)
RETURNING animation_start_tick;
UPDATE doom.actors SET health = 0 WHERE game_id = :game_id AND kind = :'actor_kind'
RETURNING animation_start_tick;
COMMIT;
SQL
)
if [ "$observed_actor" != "$(printf '%s\n' 1 1)" ]; then
    printf 'expected both edits to use committed tick 1, observed %s\n' "$observed_actor" >&2
    exit 1
fi
finish_peers
assert_player '6|100|168|1'

# Movement sees the committed blocker without waiting on an uncommitted health edit.
db -c "UPDATE doom.actors SET x = 205, y = 128, health = 31 WHERE game_id = $game_id AND kind <> 'player'"
start_owner "UPDATE doom.actors SET health = 0 WHERE game_id = $game_id AND kind <> 'player'"
blocked=$(db -v game_id="$game_id" <<'SQL'
BEGIN;
SET LOCAL lock_timeout = '1s';
SELECT doom.tick(:game_id, 1) AS tick_number \gset
SELECT abs(x - 173) < 0.00002 FROM doom.actors WHERE game_id = :game_id AND kind = 'player';
COMMIT;
SQL
)
if [ "$blocked" != t ]; then
    printf 'expected uncommitted death to leave the actor blocking movement\n' >&2
    exit 1
fi
finish_owner
released=$(db -v game_id="$game_id" <<'SQL'
SELECT doom.tick(:game_id, 1) AS tick_number \gset
SELECT abs(x - 181) < 0.00002 FROM doom.actors WHERE game_id = :game_id AND kind = 'player';
SQL
)
if [ "$released" != t ]; then
    printf 'expected committed death to release the path\n' >&2
    exit 1
fi

db -v game_id="$game_id" -v level_id="$level_id" <<'SQL'
INSERT INTO doom.sectors (level_id, sector_id, floor_height, ceiling_height)
VALUES (:level_id, 1, 0, 8);
INSERT INTO doom.lines (level_id, line_id, x1, y1, x2, y2, front_sector_id)
VALUES (:level_id, 4, 220, 200, 220, 64, 0);
INSERT INTO doom.gates (level_id, sector_id, closed_ceiling, open_ceiling, units_per_tick)
VALUES (:level_id, 1, 8, 72, 16);
INSERT INTO doom.gate_controls (level_id, line_id, sector_id) VALUES (:level_id, 4, 1);
SQL

assert_gate() {
    actual=$(db -c "SELECT state.floor_height, state.ceiling_height, player.z
        FROM doom.sector_state AS state JOIN doom.actors AS player USING (game_id)
        WHERE state.game_id = $game_id AND state.sector_id = 1 AND player.kind = 'player'")
    if [ "$actual" != "$1" ]; then
        printf 'expected floor|ceiling|player z = %s, observed %s\n' "$1" "$actual" >&2
        return 1
    fi
}

advance_owner_tick() {
    printf "SET LOCAL lock_timeout = '1s';\nSELECT doom.tick(%s, 0.125);\nSELECT 1 AS doom_concurrency_advanced;\n" \
        "$game_id" >&3
    wait_for_peer "$owner_app" advanced
}

# The idle tick should see the pending gate motion after the prior tick commits.
start_owner "SELECT doom.tick($game_id, p_use => true)"
PGAPPNAME="$tick_app" db -c "SELECT doom.tick($game_id)" >"$scratch/tick.log" 2>&1 3>&- &
tick_pid=$!
wait_for_peer "$tick_app" blocked
finish_peers
assert_gate '0|40|0'

# Hold the player while a raw floor update needs its lock for the carry trigger.
db -c "UPDATE doom.actors SET x = 250, sector_id = 1 WHERE game_id = $game_id AND kind = 'player'"
start_owner "SELECT actor_id FROM doom.actors WHERE game_id = $game_id AND kind = 'player' FOR NO KEY UPDATE"
PGAPPNAME="$tick_app" db -c "UPDATE doom.sector_state SET floor_height = 4
    WHERE game_id = $game_id AND sector_id = 1" >"$scratch/tick.log" 2>&1 3>&- &
tick_pid=$!
wait_for_peer "$tick_app" blocked
advance_owner_tick
finish_peers
assert_gate '4|40|4'
db -c "SELECT doom.tick($game_id)" >/dev/null
assert_gate '4|56|4'

# The same lock order can occur while another session inserts the first override.
db -c "DELETE FROM doom.sector_state WHERE game_id = $game_id AND sector_id = 1"
start_owner "SELECT actor_id FROM doom.actors WHERE game_id = $game_id AND kind = 'player' FOR NO KEY UPDATE"
PGAPPNAME="$tick_app" db -c "INSERT INTO doom.sector_state (game_id, level_id, sector_id, floor_height, ceiling_height)
    VALUES ($game_id, $level_id, 1, 6, 44)" >"$scratch/tick.log" 2>&1 3>&- &
tick_pid=$!
wait_for_peer "$tick_app" blocked
advance_owner_tick
finish_peers
assert_gate '6|44|6'
db -c "SELECT doom.tick($game_id)" >/dev/null
assert_gate '6|60|6'

# A hit uses the target's committed health after waiting for its row.
target_id=$(db -v game_id="$game_id" -v actor_kind="$actor_kind" <<'SQL'
INSERT INTO doom.actors (game_id, sector_id, kind, x, y)
VALUES (:game_id, 1, :'actor_kind', 300, 128)
RETURNING actor_id;
SQL
)
start_owner "UPDATE doom.actors SET health = 100 WHERE game_id = $game_id AND actor_id = $target_id"
PGAPPNAME="$tick_app" db -c "SELECT doom.tick($game_id, p_fire => true)" >"$scratch/tick.log" 2>&1 3>&- &
tick_pid=$!
wait_for_peer "$tick_app" blocked
finish_peers
health=$(db -c "SELECT health FROM doom.actors WHERE game_id = $game_id AND actor_id = $target_id")
if [ "$health" != 80 ]; then
    printf 'expected committed target health minus hit damage to be 80, observed %s\n' "$health" >&2
    exit 1
fi

# Pursuit defers a locked actor and observes SQL death and revival on later ticks.
db -v actor_kind="$actor_kind" <<'SQL'
INSERT INTO doom.actor_pursuits (kind, sight_range, move_distance, interval_ticks)
VALUES (:'actor_kind', 256, 4, 1);
SQL
start_owner "UPDATE doom.actors SET health = 0 WHERE game_id = $game_id AND actor_id = $target_id"
unmoved=$(db -v game_id="$game_id" -v target_id="$target_id" <<'SQL'
BEGIN;
SET LOCAL lock_timeout = '1s';
SELECT doom.tick(:game_id) AS tick_number \gset
SELECT x = 300 AND health = 80 FROM doom.actors WHERE game_id = :game_id AND actor_id = :target_id;
COMMIT;
SQL
)
if [ "$unmoved" != t ]; then
    printf 'expected pursuit to defer an actor with an uncommitted health edit\n' >&2
    exit 1
fi
finish_owner
resumed=$(db -v game_id="$game_id" -v target_id="$target_id" <<'SQL'
SELECT doom.tick(:game_id) AS tick_number \gset
SELECT x = 300 AND health = 0 FROM doom.actors WHERE game_id = :game_id AND actor_id = :target_id;
UPDATE doom.actors SET health = 80 WHERE game_id = :game_id AND actor_id = :target_id;
SELECT doom.tick(:game_id) AS tick_number \gset
SELECT x = 296 AND health = 80 FROM doom.actors WHERE game_id = :game_id AND actor_id = :target_id;
SQL
)
if [ "$resumed" != "$(printf '%s\n' t t)" ]; then
    printf 'expected committed death to stop pursuit and later revival to resume it\n' >&2
    exit 1
fi

# A tick waiting on completion observes the finished game without advancing it.
db -c "INSERT INTO doom.level_exits (level_id, sector_id) VALUES ($level_id, 1)"
finish_tick=$(db -c "SELECT tick_number + 1 FROM doom.games WHERE game_id = $game_id")
finish_x=$(db -c "SELECT x FROM doom.actors WHERE game_id = $game_id AND kind = 'player'")
start_owner "SELECT doom.tick($game_id, p_ticks => 6)"
PGAPPNAME="$tick_app" db -c "SELECT doom.tick($game_id, p_forward => 1, p_ticks => 6)" >"$scratch/tick.log" 2>&1 3>&- &
tick_pid=$!
wait_for_peer "$tick_app" blocked
finish_peers
finished=$(db -c "SELECT game.tick_number, game.finished_at_tick, player.x
    FROM doom.games AS game JOIN doom.actors AS player USING (game_id)
    WHERE game.game_id = $game_id AND player.kind = 'player'")
if [ "$finished" != "$finish_tick|$finish_tick|$finish_x" ] || [ "$(cat "$scratch/tick.log")" != "$finish_tick" ]; then
    printf 'expected both ticks to stop at finish tic %s, observed %s\n' "$finish_tick" "$finished" >&2
    exit 1
fi

# A frame sees the palette and its shades from the same committed version.
db -v level_id="$level_id" <<'SQL'
INSERT INTO doom.level_palettes (level_id, palette) VALUES (:level_id, decode(repeat('c86432', 256), 'hex'));
INSERT INTO doom.level_materials (level_id, surface_kind, name, width, height, pixels, coverage)
VALUES (:level_id, 'flat', 'MVCC', 1, 1, '\x00', '\xff');
SQL
palette_texel() {
    db -v level_id="$level_id" <<'SQL'
SELECT encode(doom._sample_render_frame(:level_id, ARRAY[
    ROW(0, 0, 1, '\x000000', ROW('flat', 'MVCC', 127, 0, 0, 0, 0, false)::doom._render_mapping)
]::doom._render_span[], 0.5, false), 'hex');
SQL
}
start_owner "UPDATE doom.level_palettes SET palette = decode(repeat('142850', 256), 'hex') WHERE level_id = $level_id"
if [ "$(palette_texel)" != 643219 ]; then
    printf 'expected the original shade while the update was uncommitted\n' >&2
    exit 1
fi
finish_owner
if [ "$(palette_texel)" != 0a1428 ]; then
    printf 'expected the new shade immediately after the palette update committed\n' >&2
    exit 1
fi

# Reimport must compare against the locked palette, even when the visible bytes already match.
start_owner "UPDATE doom.level_palettes SET palette = decode(repeat('c86432', 256), 'hex') WHERE level_id = $level_id"
PGAPPNAME="$tick_app" db -c "SELECT doom.import_wad_materials($level_id,
    decode('50574144010000000c030000' || repeat('142850', 256) || '0c00000000030000504c415950414c00', 'hex'))" \
    >"$scratch/tick.log" 2>&1 3>&- &
tick_pid=$!
wait_for_peer "$tick_app" blocked
finish_peers
shade=$(db -c "SELECT encode(substring(shade_bytes FROM 127 * 768 + 1 FOR 3), 'hex')
    FROM doom.level_palettes WHERE level_id = $level_id")
if [ "$shade" != 0a1428 ]; then
    printf 'expected reimport to replace the palette committed while it waited\n' >&2
    exit 1
fi

printf 'Concurrent ticks, SQL edits, contacts, gates, shots, pursuit, completion and palette checks passed.\n'
