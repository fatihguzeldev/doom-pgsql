#!/bin/sh
# Usage: PYTHON=path/to/python bench/ps5.sh doom1.wad [seconds]
set -eu
wad=${1:?path to a shareware WAD required}
duration=${2:-60}
python=${PYTHON:-python3}
repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
name=doom-pgsql-bench-$$
if docker inspect "$name" >/dev/null 2>&1; then exit 1; fi
docker run -d --rm --name "$name" --memory=512m --memory-swap=512m \
    -p 127.0.0.1::5432 -e POSTGRES_HOST_AUTH_METHOD=trust postgres:17 >/dev/null
trap 'docker stop "$name" >/dev/null' EXIT
export PGHOST=127.0.0.1 PGUSER=postgres PGDATABASE=postgres
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
level=$("$python" - "$wad" <<'PY'
import psycopg,sys
from pathlib import Path
with psycopg.connect() as c:
    print(c.execute("select doom.load_wad(%s,'E1M3')",(Path(sys.argv[1]).read_bytes(),)).fetchone()[0])
PY
)
psql -Xqc 'ANALYZE'
"$python" -B "$repo/bench/replay.py" --level "$level" --seconds "$duration" --container "$name"
