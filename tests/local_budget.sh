#!/bin/sh
set -eu

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    printf 'usage: %s WAD MAP [SECONDS]\n' "$0" >&2
    exit 2
fi

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
wad=$(CDPATH='' cd -- "$(dirname -- "$1")" && pwd)/$(basename -- "$1")
map=$2
seconds=${3:-60}
profile=${DOOM_NETWORK_PROFILE:-normal}
period=${DOOM_CPU_PERIOD:-100000}
case $period in 20000|100000) ;; *) exit 2 ;; esac
if [ ! -f "$wad" ]; then
    printf 'WAD file is missing\n' >&2
    exit 2
fi

container=doom-local-budget-$$
if docker inspect "$container" >/dev/null 2>&1; then
    printf 'Container %s already exists\n' "$container" >&2
    exit 1
fi

docker run --detach --rm --name "$container" --memory=512m --memory-swap=512m \
    -e POSTGRES_HOST_AUTH_METHOD=trust -p 127.0.0.1::5432 \
    --mount "type=bind,source=$repo,target=/work,readonly" \
    --mount "type=bind,source=$wad,target=/input.wad,readonly" \
    postgres:17 -c jit=off -c max_parallel_workers_per_gather=0 >/dev/null
trap 'docker stop --time 2 "$container" >/dev/null 2>&1 || :' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

attempt=0
until docker exec "$container" pg_isready -h 127.0.0.1 -U postgres -q; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 50 ] || exit 1
    sleep .2
done

docker exec -u postgres "$container" openssl req -new -x509 -nodes -days 1 -subj /CN=localhost \
    -keyout /tmp/local-postgres.key -out /tmp/local-postgres.crt 2>/dev/null
docker exec -u postgres "$container" chmod 600 /tmp/local-postgres.key
docker exec "$container" psql -Xq -v ON_ERROR_STOP=1 -U postgres \
    -c "ALTER SYSTEM SET ssl_key_file TO '/tmp/local-postgres.key'" \
    -c "ALTER SYSTEM SET ssl_cert_file TO '/tmp/local-postgres.crt'" \
    -c 'ALTER SYSTEM SET ssl TO on' \
    -c 'SELECT pg_reload_conf()' >/dev/null

docker exec "$container" psql -Xq -v ON_ERROR_STOP=1 -U postgres -f /work/install.sql
ids=$(docker exec -i "$container" psql -XAtq -v ON_ERROR_STOP=1 -v map="$map" -U postgres <<'SQL'
SELECT doom.load_wad(pg_read_binary_file('/input.wad'), :'map') AS level \gset
SELECT doom.start(:level, 3) FROM generate_series(1, 2);
ANALYZE;
SQL
)

unset PGHOSTADDR PGSERVICE
export PGHOST=127.0.0.1 PGUSER=postgres PGDATABASE=postgres PGSSLMODE=require
PGPORT=$(docker port "$container" 5432/tcp | cut -d: -f2)
export PGPORT
set -- $ids
python3 -B "$repo/tests/benchmark_play.py" "$1" --seconds "$seconds" --container "$container"
docker update --cpu-period "$period" --cpu-quota "$((period / 16))" "$container" >/dev/null
limits=$(docker exec "$container" cat /sys/fs/cgroup/cpu.max /sys/fs/cgroup/cpu.max.burst \
    /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory.swap.max)
expected=$(printf '%s %s\n0\n536870912\n0' "$((period / 16))" "$period")
if [ "$limits" != "$expected" ]; then
    printf 'Unexpected local cgroup limits:\n%s\n' "$limits" >&2
    exit 1
fi
printf 'CPU quota: %s/%s µs; memory: 512 MiB; no burst or swap\n' "$((period / 16))" "$period" >&2
python3 -B "$repo/tests/benchmark_play.py" --control --seconds "$seconds" --profile "$profile" --container "$container"
python3 -B "$repo/tests/benchmark_play.py" "$2" --seconds "$seconds" --profile "$profile" --container "$container"
