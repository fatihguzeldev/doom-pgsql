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

finish_peers() {
    printf 'COMMIT;\n' >&3
    exec 3>&-
    wait "$owner_pid"
    owner_pid=
    wait "$tick_pid"
    tick_pid=
}

assert_player() {
    actual=$(db -c "SELECT g.tick_number, a.health, a.x
        FROM doom.games AS g JOIN doom.actors AS a USING (game_id)
        WHERE g.game_id = $game_id AND a.kind = 'player'")
    if [ "$actual" != "$1" ]; then
        printf 'expected tick|health|x = %s, observed %s\n' "$1" "$actual" >&2
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
assert_player '1|0|128'

# Ticks serialize, while independent actor inserts can commit during a tick transaction.
db -c "UPDATE doom.actors SET health = 100 WHERE game_id = $game_id AND kind = 'player'"
start_owner "SELECT doom.tick($game_id, 1, 0, 0, 2)"
PGAPPNAME="$tick_app" db -c "SELECT doom.tick($game_id, 1, 0, 0, 3)" >"$scratch/tick.log" 2>&1 3>&- &
tick_pid=$!
wait_for_peer "$tick_app" blocked
db -v game_id="$game_id" -v actor_kind="$actor_kind" <<'SQL'
BEGIN;
SET LOCAL lock_timeout = '1s';
INSERT INTO doom.actors (game_id, kind, x, y) VALUES (:game_id, :'actor_kind', 400, 400);
COMMIT;
SQL
finish_peers
assert_player '6|100|168'
printf 'Concurrent tick, SQL edit and spawn checks passed.\n'
