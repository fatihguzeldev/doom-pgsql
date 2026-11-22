import argparse
import hashlib
import json
import math
import os
import subprocess
import sys
from contextlib import contextmanager
from pathlib import Path
from statistics import mean

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from client.pg import Connection, integer
from client.session import FRAME, FRAME_RATE, GAME, TICK, TIC_RATE, pipeline_limit, run


PROFILES = {
    'loopback': (0, 0),
    'normal': (50, 0),
    'stress': (80, 60),
}


def input_at(tic):
    if tic <= 12:
        return 1, 0, 0, False, False
    if tic == 13:
        return 0, 0, 0, True, False
    if tic < 36:
        return 0, 0, 0.016 if tic <= 24 else -0.016, False, False
    if tic < 56:
        return 1, 0, 0, False, tic in (43, 52)
    if tic <= 70:
        return 0.4, 0.25, 0.035 if tic <= 64 else -0.025, False, tic in (61, 70)
    if tic in (71, 109):
        return 0, 0, math.pi if tic == 109 else math.pi - 0.165, False, False
    if tic < 109:
        return 1, 0, 0, False, False
    direction = 1 if (tic - 110) % 64 < 32 else -1
    return 0.75 * direction, 0.15 * direction, 0.012 * direction, False, tic % 9 == 0


@contextmanager
def network(profile):
    rtt, spike = PROFILES[profile]
    if not rtt:
        yield b''
        return
    host = os.environ.get('PGHOSTADDR') or os.environ.get('PGHOST', '127.0.0.1')
    command = [sys.executable, '-B', str(Path(__file__).with_name('latency_proxy.py')),
               '--target-host', host, '--target-port', os.environ.get('PGPORT', '5432'),
               '--rtt-ms', str(rtt), '--upload', '60', '--download', '250']
    if spike:
        command += ['--spike-ms', str(spike), '--spike-period', '5']
    with subprocess.Popen(command, stdout=subprocess.PIPE, text=True) as proxy:
        try:
            port = proxy.stdout.readline().strip()
            if not port.isdecimal():
                raise RuntimeError('network proxy did not open a loopback socket')
            yield f'hostaddr=127.0.0.1 port={port}'.encode()
        finally:
            if proxy.poll() is None:
                proxy.terminate()


def cpu_counts(container, *pids):
    if not container:
        return None
    paths = ['/sys/fs/cgroup/cpu.stat', *(f'/proc/{pid}/schedstat' for pid in pids)]
    lines = subprocess.check_output(['docker', 'exec', container, 'cat', *paths], text=True).splitlines()
    totals = {}
    for lane, pid in zip(('tick_cpu_usec', 'frame_cpu_usec'), reversed(pids)):
        # The proc entries are the final lines, in the opposite order of these pops.
        totals[lane] = int(lines.pop().split()[0]) // 1000
    counts = dict(line.split() for line in lines)
    totals['cpu_usec'] = int(counts['usage_usec'])
    totals['throttled_periods'] = int(counts['nr_throttled'])
    return totals


def control(writer, reader):
    writer.execute(b'CREATE TEMP TABLE benchmark_state (tic bigint)')
    writer.execute(b'INSERT INTO benchmark_state VALUES (0)')
    writer.prepare(b'''UPDATE benchmark_state SET tic = $3::bigint
        WHERE $1::bigint = 1 AND $2::bigint = 1 AND $4::float8 IS NOT NULL
            AND $5::float8 IS NOT NULL AND $6::float8 IS NOT NULL
            AND $7::boolean IS NOT NULL AND $8::boolean IS NOT NULL RETURNING tic''')
    reader.execute(b'''CREATE TEMP TABLE benchmark_frame AS
        SELECT string_agg(int2send((y * 160 + x)::smallint) || decode('1000','hex') ||
            decode(repeat('8f', 16), 'hex'), ''::bytea ORDER BY y, x) AS pixels
        FROM generate_series(0, 99) AS y CROSS JOIN generate_series(0, 144, 16) AS x''')
    reader.prepare(b'SELECT $2::bigint, $3::bigint, $3::bigint, 0, pixels FROM benchmark_frame WHERE $1::bigint = 1')
    return 1, 0


def state_at(connection, game):
    return json.loads(connection.execute(b'''
        SELECT json_build_object('tic', g.tick_number, 'level', l.name, 'sector', a.sector_id,
            'x', a.x, 'y', a.y, 'angle', a.angle, 'health', a.health,
            'door64', (SELECT ceiling_height FROM doom.sector_state WHERE game_id = g.game_id AND sector_id = 64))::text
        FROM doom.games AS g JOIN doom.levels AS l USING (level_id)
        JOIN doom.actors AS a USING (game_id) WHERE g.game_id = $1 AND a.kind = 'player'
    ''', game)[0])


def percentile(values, quantile):
    return round(sorted(values)[math.ceil(len(values) * quantile) - 1], 3) if values else None


def measure(args, options):
    frames, tics, distinct = [], [], set()
    game = args.game or 1
    with Connection(options) as writer, Connection(options) as reader:
        pids = [integer(connection.execute(b'SELECT pg_backend_pid()')[0]) for connection in (reader, writer)]
        writer.execute(b"SET default_transaction_isolation TO 'repeatable read'")
        if args.control:
            epoch, first_tic = control(writer, reader)
            initial = None
        else:
            epoch, first_tic = map(integer, writer.execute(GAME, game))
            initial = state_at(writer, game)
            writer.prepare(TICK)
            reader.prepare(FRAME)
        for lane in (writer, reader):
            lane.start_pipeline()

        def on_frame(snapshot, slot, palette, pixels, size, due, ready):
            digest = hashlib.blake2b(digest_size=8)
            for channel in pixels:
                digest.update(channel)
            distinct.add((palette, digest.digest()))
            if not frames or snapshot > frames[-1][0]:
                frames.append((snapshot, slot, size, due, ready))

        before = cpu_counts(args.container, *pids)
        counts = run(writer, reader, game, epoch, first_tic,
                     lambda tic: input_at(tic - first_tic), on_frame,
                     lambda tic, due, accepted: tics.append((tic, due, accepted)),
                     duration=args.seconds, in_flight=args.in_flight or pipeline_limit(sum(PROFILES[args.profile])))
        after = cpu_counts(args.container, *pids)
    gaps = [(following[4] - current[4]) * 1000 for current, following in zip(frames, frames[1:])]
    signals = []
    index = 0
    if not args.control:
        for tic, due, _ in tics:
            while index < len(frames) and frames[index][0] < tic:
                index += 1
            if index < len(frames):
                signals.append((frames[index][4] - due) * 1000)
    summary = {**counts, 'profile': args.profile, 'control': args.control, 'seconds': args.seconds,
               'fresh_frames': len(frames), 'fresh_fps': round(len(frames) / args.seconds, 3),
               'distinct_images': len(distinct), 'applied_tics': len(tics),
               'tics_per_second': round(len(tics) / args.seconds, 3),
               'frame_bytes_mean': round(mean(frame[2] for frame in frames), 1) if frames else None,
               'frame_gap_ms_p95': percentile(gaps, .95), 'frame_gap_ms_p99': percentile(gaps, .99),
               'frame_ready_ms_p95': percentile([(x[4] - x[3]) * 1000 for x in frames], .95),
               'commit_ms_p95': percentile([(ready - due) * 1000 for _, due, ready in tics], .95),
               'input_to_frame_ms_p95': percentile(signals, .95), 'start': initial}
    if after is not None:
        summary['cpu'] = {key: after[key] - before[key] for key in after}
        if tics:
            summary['tick_cpu_ms'] = round(summary['cpu']['tick_cpu_usec'] / (1000 * len(tics)), 3)
        if counts['frame_requests']:
            summary['frame_cpu_ms_per_request'] = round(summary['cpu']['frame_cpu_usec'] /
                                                        (1000 * counts['frame_requests']), 3)
    if not args.control:
        with Connection(options) as inspector:
            summary['end'] = state_at(inspector, game)
    return summary


def main():
    parser = argparse.ArgumentParser(description='Measure real 160×100 frames and 35 Hz simulation over binary PostgreSQL.')
    parser.add_argument('game', type=int, nargs='?')
    parser.add_argument('--control', action='store_true', help='send already packed frames and commit simple state updates')
    parser.add_argument('--profile', choices=PROFILES, default='loopback')
    parser.add_argument('--seconds', type=float, default=60)
    parser.add_argument('--in-flight', type=int, help='override each connection’s outstanding request limit')
    parser.add_argument('--container', help='read CPU accounting from this local Docker container')
    args = parser.parse_args()
    if (args.control == (args.game is not None) or not math.isfinite(args.seconds) or args.seconds < 1
            or args.game is not None and args.game < 1 or args.in_flight is not None and args.in_flight < 1):
        parser.error('specify a positive game ID or --control, a duration of at least one second, and a positive limit')
    with network(args.profile) as options:
        print(json.dumps(measure(args, options)))


if __name__ == '__main__':
    main()
