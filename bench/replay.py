"""Measure native frames and acknowledged tics through PostgreSQL's public game API."""

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


def measure(dsn, game, seconds, rtt, container=None, commands=None):
    barrier = threading.Barrier(3, timeout=30)
    begin_work = threading.Event()
    pids = {}
    start = finish = 0.0

    def backend_cpu():
        if not container:
            return {}
        paths = [f"/proc/{pids[lane]}/schedstat" for lane in ("writer", "reader")]
        rows = subprocess.check_output(["docker", "exec", container, "cat", *paths], text=True).splitlines()
        return {lane: int(row.split()[0]) / 1e6 for lane, row in zip(("writer", "reader"), rows)}

    delay = rtt / 2000

    def inputs(writer):
        nonlocal finish
        timings, accepted = [], 0
        epoch, initial = writer.execute("SELECT epoch,tic FROM doom.game_status(%s)", (game,)).fetchone()
        barrier.wait()
        begin_work.wait()
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
        (epoch,) = reader.execute("SELECT epoch FROM doom.game_status(%s)", (game,)).fetchone()
        barrier.wait()
        begin_work.wait()
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
        pids.update(writer=write_conn.info.backend_pid, reader=read_conn.info.backend_pid)
        with ThreadPoolExecutor(max_workers=2) as pool:
            writer, reader = (
                pool.submit(inputs, write_conn),
                pool.submit(frames, read_conn),
            )
            try:
                barrier.wait()
                before = backend_cpu()
                start = time.monotonic()
                finish = start + seconds
            finally:
                begin_work.set()
            tics, w = writer.result()
            fresh, distinct, reused, f = reader.result()
            after = backend_cpu()
    if commands is not None:
        elapsed = finish - start
        if tics != len(commands):
            raise RuntimeError(f"exit route timed out at tic {tics}")
        with psycopg.connect(dsn) as conn:
            if not conn.execute("SELECT finished FROM doom.game_status(%s)", (game,)).fetchone()[0]:
                raise RuntimeError("the replay did not finish Hangar")
    else:
        elapsed = seconds
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
        "median_frame_request_ms": statistics.median(f) if f else None,
        "median_input_batch_ms": statistics.median(w) if w else None,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
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
        help="added delay split between each request and response",
    )
    args = parser.parse_args()
    if args.seconds <= 0 or args.rtt_ms < 0:
        parser.error("duration must be positive and RTT nonnegative")
    with psycopg.connect(args.dsn, autocommit=True) as c:
        level = (
            args.level
            or c.execute(
                "SELECT doom.load_wad(%s,%s)",
                (args.wad.read_bytes(), "E1M1" if args.hangar_exit else args.map),
            ).fetchone()[0]
        )
        game = c.execute(
            "SELECT game_id FROM doom.new_game(%s,%s)",
            (level, 1 if args.hangar_exit else 3),
        ).fetchone()[0]
    print(
        json.dumps(
            measure(
                args.dsn,
                game,
                args.seconds,
                args.rtt_ms,
                args.container,
                hangar_commands() if args.hangar_exit else None,
            ),
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
