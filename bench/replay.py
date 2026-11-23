import argparse
import hashlib
import json
import math
import statistics
import subprocess
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import psycopg
from psycopg.types.json import Jsonb


def route(n):
    if n <= 32:
        return [1, 0, 0, n == 13, n == 26]
    if n <= 68:
        return [0.6, 0, 0.035, False, n % 13 == 0]
    heading = 1 if ((n - 69) // 64) % 2 == 0 else -1
    return [0.6, 0.25, 0.035 * heading, n % 71 == 0, n % 11 == 0]


def hangar_commands():
    path = Path(__file__).resolve().parents[1] / "tests/fixtures/e1m1-exit.json"
    commands = []
    for count, forward, turn in json.loads(path.read_text()):
        for _ in range(count):
            commands.append([forward, 0, turn, True, len(commands) % 8 == 0])
    return commands


def backend_cpu_ms(container, writer, reader):
    if not container:
        return {}
    pids = (writer.info.backend_pid, reader.info.backend_pid)
    paths = [f"/proc/{pid}/schedstat" for pid in pids]
    rows = subprocess.check_output(["docker", "exec", container, "cat", *paths], text=True).splitlines()
    return {lane: int(row.split()[0]) / 1e6 for lane, row in zip(("writer", "reader"), rows, strict=True)}


def measure(dsn, game, seconds, rtt, container=None, commands=None):
    delay = rtt / 2000
    start = finish = 0.0

    def start_clock():
        nonlocal start, finish
        start = time.monotonic()
        finish = start + seconds

    ready = threading.Barrier(2, action=start_clock, timeout=30)

    def inputs(writer):
        nonlocal finish
        timings, accepted = [], 0
        ready.wait()
        pending = 1
        while time.monotonic() < finish:
            now = time.monotonic()
            last = min(math.floor((now - start) * 35) + 1, pending + 15)
            if commands is not None:
                last = min(last, len(commands))
            if pending > last:
                time.sleep(max(0, start + (pending - 1) / 35 - now))
                continue
            batch = (
                commands[pending - 1 : last]
                if commands is not None
                else [route(n) for n in range(pending, last + 1)]
            )
            time.sleep(delay)
            (acknowledged,) = writer.execute(
                "CALL doom.submit(%s,%s,%s,%s)",
                (game, epoch, initial + pending, Jsonb(batch)),
            ).fetchone()
            time.sleep(delay)
            if time.monotonic() <= finish:
                accepted += max(0, min(last, acknowledged - initial) - pending + 1)
                timings.append(1000 * (time.monotonic() - now))
            if acknowledged < initial + last:
                break
            pending = last + 1
            if commands is not None and last == len(commands):
                finish = min(finish, time.monotonic())
                break
        return accepted, timings

    def frames(reader):
        timings, pictures, fresh, repeated, sent = [], set(), 0, 0, 0
        token = None
        ready.wait()
        while time.monotonic() < finish:
            now = time.monotonic()
            sent += 1
            time.sleep(delay)
            pic, light, token = reader.execute(
                "SELECT pixels,shades,token FROM doom.poll_frame(%s,%s,%s,%s)",
                (game, epoch, sent, token),
                binary=True,
            ).fetchone()
            time.sleep(delay)
            if time.monotonic() <= finish:
                timings.append(1000 * (time.monotonic() - now))
                if pic is None:
                    repeated += 1
                else:
                    fresh += 1
                    pictures.add(hashlib.blake2s(pic + light).digest())
            time.sleep(max(0, 1 / 30 - (time.monotonic() - now)))
        return fresh, len(pictures), repeated, timings

    with (
        psycopg.connect(dsn, autocommit=True) as write_conn,
        psycopg.connect(dsn, autocommit=True) as read_conn,
    ):
        epoch, initial = write_conn.execute("SELECT epoch,tic FROM doom.game_status(%s)", (game,)).fetchone()
        before = backend_cpu_ms(container, write_conn, read_conn)
        with ThreadPoolExecutor(max_workers=2) as pool:
            writer = pool.submit(inputs, write_conn)
            reader = pool.submit(frames, read_conn)
            tics, input_times = writer.result()
            fresh, distinct, reused, frame_times = reader.result()
        after = backend_cpu_ms(container, write_conn, read_conn)
        if commands is not None:
            if tics != len(commands):
                raise RuntimeError(f"exit route timed out at tic {tics}")
            if not write_conn.execute("SELECT finished FROM doom.game_status(%s)", (game,)).fetchone()[0]:
                raise RuntimeError("the replay did not finish Hangar")
    elapsed = seconds if commands is None else finish - start
    cpu = {lane: round(after[lane] - ms, 3) for lane, ms in before.items()}
    return {
        "backend_cpu_ms_including_drain": cpu,
        "seconds": elapsed,
        "artificial_rtt_ms": rtt,
        "acknowledged_tics": tics,
        "tics_per_s": tics / elapsed,
        "sql_frames": fresh,
        "unique_images": distinct,
        "unique_fps": distinct / elapsed,
        "reused": reused,
        "median_frame_request_ms": statistics.median(frame_times) if frame_times else None,
        "median_input_batch_ms": statistics.median(input_times) if input_times else None,
    }


def main():
    parser = argparse.ArgumentParser(description="Measure distinct SQL frames and acknowledged game tics per second.")
    parser.add_argument("--dsn", default="")
    parser.add_argument("--container", help="read CPU counters for this local PostgreSQL container")
    which = parser.add_mutually_exclusive_group(required=True)
    which.add_argument("--wad", type=Path)
    which.add_argument("--level", type=int)
    parser.add_argument("--map", default="E1M3")
    parser.add_argument(
        "--hangar-exit",
        action="store_true",
        help="play the shareware E1M1 exit route at skill 1",
    )
    parser.add_argument("--seconds", type=float, default=60)
    parser.add_argument(
        "--rtt-ms",
        type=float,
        default=50,
        help="add half the delay before each request and half after its response",
    )
    args = parser.parse_args()
    if not 0 < args.seconds < math.inf or not 0 <= args.rtt_ms < math.inf:
        parser.error("duration and RTT must be finite, with duration > 0 and RTT >= 0")
    with psycopg.connect(args.dsn, autocommit=True) as c:
        level = args.level
        if args.wad is not None:
            level = c.execute(
                "SELECT doom.load_wad(%s,%s)",
                (args.wad.read_bytes(), "E1M1" if args.hangar_exit else args.map),
            ).fetchone()[0]
        game = c.execute(
            "SELECT game_id FROM doom.new_game(%s,%s)",
            (level, 1 if args.hangar_exit else 3),
        ).fetchone()[0]
    commands = hangar_commands() if args.hangar_exit else None
    result = measure(args.dsn, game, args.seconds, args.rtt_ms, args.container, commands)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
