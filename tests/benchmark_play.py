"""Measure fresh frames and applied game tics under concurrent live WAD input."""

import argparse
import ctypes as C
import hashlib
import json
import math
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack
from struct import Struct
from threading import Event
from time import perf_counter

from benchmark import checked_result, connection_options, libpq


TIC_RATE = 35
FRAME_RATE = 30
BLOCK_HEADER = Struct('!HHH')


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
    if tic == 71:
        return 0, 0, math.pi - 0.165, False, False
    if tic < 109:
        return 1, 0, 0, False, False
    if tic == 109:
        return 0, 0, math.pi, False, False
    if (tic - 110) % 64 < 32:
        return 0.75, 0.15, 0.012, False, tic % 9 == 0
    return -0.75, -0.15, -0.012, False, tic % 9 == 0


def p95(values):
    return round(sorted(values)[math.ceil(0.95 * len(values)) - 1], 3) if values else None


def unpack_blocks(payload, width, height):
    image = bytearray(width * height * 3)
    coverage = [0] * width
    offset = 0
    pixels = 0
    while offset < len(payload):
        if len(payload) - offset < BLOCK_HEADER.size:
            raise RuntimeError("truncated RGB block header")
        column, row, count = BLOCK_HEADER.unpack_from(payload, offset)
        offset += BLOCK_HEADER.size
        size = count * 3
        if column >= width or row + count > height or count == 0 or offset + size > len(payload):
            raise RuntimeError("invalid RGB block bounds")
        rows = ((1 << count) - 1) << row
        if coverage[column] & rows:
            raise RuntimeError("overlapping RGB blocks")
        coverage[column] |= rows
        destination = (column * height + row) * 3
        image[destination:destination + size] = payload[offset:offset + size]
        offset += size
        pixels += count
    if pixels != width * height:
        raise RuntimeError("RGB blocks did not fill frame")
    return image


def connect(stack, lib, options):
    connection = lib.PQconnectdb(options)
    if not connection:
        raise RuntimeError("libpq could not allocate a connection")
    stack.callback(lib.PQfinish, connection)
    if lib.PQstatus(connection) != 0:
        raise RuntimeError(lib.PQerrorMessage(connection).decode().strip())
    return connection


def measure(args, options):
    lib = libpq()
    sizes = args.width, args.height
    halted = Event()

    def prepare(connection, name, query, count):
        result = lib.PQprepare(connection, name, query, count, None)
        lib.PQclear(checked_result(lib, connection, result, 1))

    def call(connection, name, *values):
        params = (C.c_char_p * len(values))(*(str(value).encode() for value in values))
        result = lib.PQexecPrepared(connection, name, len(values), params, None, None, 1)
        return checked_result(lib, connection, result, 2)

    def field(result, index):
        if lib.PQntuples(result) != 1:
            raise RuntimeError("expected one row")
        length = lib.PQgetlength(result, 0, index)
        return C.string_at(lib.PQgetvalue(result, 0, index), length)

    def integer(result, index):
        value = field(result, index)
        if len(value) != 8:
            raise RuntimeError("expected one bigint")
        return int.from_bytes(value, "big", signed=True)

    def state(connection):
        result = call(connection, b"state", args.game)
        try:
            return json.loads(field(result, 0))
        finally:
            lib.PQclear(result)

    def drive(connection):
        arrivals = {}
        try:
            for tic in range(1, args.tics + 1):
                due = start + tic / TIC_RATE
                if halted.wait(max(0, due - perf_counter())) or perf_counter() >= end:
                    break
                result = call(connection, b"tick", args.game, *input_at(tic))
                now = perf_counter()
                try:
                    if integer(result, 0) != initial["tic"] + tic:
                        raise RuntimeError("the game clock did not advance by one tic")
                finally:
                    lib.PQclear(result)
                arrivals[tic] = (due, now)
            return arrivals
        finally:
            halted.set()

    def draw(connection):
        frames = []
        skipped = 0
        slot = 1
        requests = 0
        while True:
            due = start + slot / FRAME_RATE
            if halted.wait(max(0, due - perf_counter())) or perf_counter() >= end:
                break
            result = call(connection, b"frame", args.game, *sizes)
            requests += 1
            try:
                if integer(result, 0) != args.game:
                    raise RuntimeError("received another game's frame")
                tic = integer(result, 1) - initial["tic"]
                payload = field(result, 2)
                if args.blocks:
                    payload = unpack_blocks(payload, *sizes)
                elif len(payload) != 3 * args.width * args.height:
                    raise RuntimeError("unexpected RGB frame size")
                if tic > (frames[-1][0] if frames else 0):
                    digest = hashlib.blake2b(payload, digest_size=8).digest()
                    frames.append((tic, perf_counter(), digest))
                if frames and tic < frames[-1][0]:
                    raise RuntimeError("received an out-of-order frame")
            finally:
                lib.PQclear(result)
            next_slot = max(slot + 1, math.floor((perf_counter() - start) * FRAME_RATE) + 1)
            skipped += next_slot - slot - 1
            slot = next_slot
        return frames, skipped, requests

    with ExitStack() as stack:
        writer, renderer = (connect(stack, lib, options) for _ in range(2))
        prepare(writer, b"tick", b"SELECT doom.tick($1, $2, $3, $4, 1, $5, $6)", 6)
        frame_query = (b"SELECT * FROM doom.render_block_snapshot($1, $2, $3)" if args.blocks else
                       b"SELECT * FROM doom.render_snapshot($1, $2, $3, true)")
        prepare(renderer, b"frame", frame_query, 3)
        prepare(writer, b"state", b"""
            SELECT json_build_object('tic', g.tick_number, 'level', l.name, 'x', a.x, 'y', a.y,
                'angle', a.angle, 'sector', a.sector_id, 'health', a.health,
                'door_height', (SELECT coalesce(state.ceiling_height, base.ceiling_height)
                    FROM doom.sectors base LEFT JOIN doom.sector_state state
                        ON state.game_id = g.game_id AND state.sector_id = base.sector_id
                    WHERE base.level_id = g.level_id AND base.sector_id = 64))
            FROM doom.games g JOIN doom.levels l USING (level_id) JOIN doom.actors a USING (game_id)
            WHERE g.game_id = $1 AND a.kind = 'player'
        """, 1)
        initial = state(writer)
        if initial["level"] != "E1M3" or initial["tic"] != 0:
            raise RuntimeError("the replay starts in a fresh E1M3 game")

        start = perf_counter() + 0.05
        end = start + args.seconds
        with ThreadPoolExecutor(max_workers=2) as workers:
            drive_task = workers.submit(drive, writer)
            draw_task = workers.submit(draw, renderer)
            arrivals = drive_task.result()
            frames, skipped, requests = draw_task.result()
        elapsed = perf_counter() - start
        final = state(writer)

    frame_gaps = [(right[1] - left[1]) * 1000 for left, right in zip(frames, frames[1:])]
    input_to_frame = []
    frame_index = 0
    for tic, (due, _) in arrivals.items():
        while frame_index < len(frames) and frames[frame_index][0] < tic:
            frame_index += 1
        if frame_index < len(frames):
            input_to_frame.append((frames[frame_index][1] - due) * 1000)
    return {
        "size": sizes,
        "encoding": "blocks" if args.blocks else "rgb",
        "applied_tics": len(arrivals),
        "elapsed_seconds": round(elapsed, 3),
        "tics_per_second": round(len(arrivals) / elapsed, 3),
        "frame_requests": requests,
        "fresh_frames": len(frames),
        "distinct_images": len({frame[2] for frame in frames}),
        "fresh_fps": round(len(frames) / elapsed, 3),
        "missed_frame_slots": skipped,
        "frame_gap_ms_p95": p95(frame_gaps),
        "tic_lateness_ms_p95": p95([(now - due) * 1000 for due, now in arrivals.values()]),
        "scheduled_input_to_frame_ms_p95": p95(input_to_frame),
        "inputs_reflected_by_frames": len(input_to_frame),
        "start": initial,
        "end": final,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("game", type=int, help="ID of a fresh E1M3 WAD game")
    parser.add_argument("--width", type=int, default=160)
    parser.add_argument("--height", type=int, default=100)
    parser.add_argument("--tics", type=int, default=2100)
    parser.add_argument("--seconds", type=float, default=60)
    parser.add_argument("--blocks", action="store_true")
    parser.add_argument("--rtt-ms", type=float)
    parser.add_argument("--mbps", type=float)
    args = parser.parse_args()
    if min(args.game, args.width, args.height, args.tics) < 1 or not math.isfinite(args.seconds) or args.seconds <= 0:
        parser.error("game, dimensions, tics and duration must be positive")
    for value in (args.rtt_ms, args.mbps):
        if value is not None and (not math.isfinite(value) or value < 0):
            parser.error("invalid network simulation settings")
    if args.mbps == 0:
        parser.error("bandwidth must be positive")
    with connection_options(args.rtt_ms, args.mbps) as options:
        print(json.dumps(measure(args, options)))


if __name__ == "__main__":
    main()
