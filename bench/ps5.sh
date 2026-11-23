#!/bin/sh
set -eu
wad=${1:?usage: bench/ps5.sh doom1.wad [seconds] [E1M3|E1M1]}
duration=${2:-60}
map=${3:-E1M3}
set --
case "$map" in
    E1M3) ;;
    E1M1) set -- --hangar-exit ;;
    *) echo 'expected E1M3 or E1M1' >&2; exit 2 ;;
esac
python=${PYTHON:-python3}
repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
name=doom-pgsql-bench-$$
if docker inspect "$name" >/dev/null 2>&1; then exit 1; fi
docker run -d --rm --name "$name" --memory=512m --memory-swap=512m \
    -p 127.0.0.1::5432 -e POSTGRES_HOST_AUTH_METHOD=trust postgres:17 >/dev/null
trap 'docker stop "$name" >/dev/null' EXIT
unset PGHOSTADDR PGSERVICE PGOPTIONS
export PGSSLMODE=disable PGHOST=127.0.0.1 PGUSER=postgres PGDATABASE=postgres
PGPORT=$(docker port "$name" 5432/tcp | cut -d: -f2)
export PGPORT
attempt=0
until pg_isready -q; do
    attempt=$((attempt+1))
    [ "$attempt" -lt 50 ] || exit 1
    sleep 0.2
done
docker update --cpu-period 100000 --cpu-quota 6250 "$name" >/dev/null
limits=$(docker exec "$name" cat /sys/fs/cgroup/cpu.max /sys/fs/cgroup/cpu.max.burst /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory.swap.max)
[ "$limits" = "$(printf '6250 100000\n0\n536870912\n0')" ] || exit 1
psql -Xq -f "$repo/install.sql"
level=$("$python" - "$wad" "$map" <<'PY'
import psycopg,sys
from pathlib import Path
with psycopg.connect() as c:
    print(c.execute("select doom.load_wad(%s,%s)",(Path(sys.argv[1]).read_bytes(),sys.argv[2])).fetchone()[0])
PY
)
psql -Xqc 'ANALYZE'
"$python" -B "$repo/bench/replay.py" --level "$level" --seconds "$duration" --container "$name" "$@"
