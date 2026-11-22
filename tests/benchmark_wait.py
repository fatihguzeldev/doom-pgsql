"""Measure how an in-flight frame affects input acknowledgement and the next frame."""

import argparse
import ctypes as C
import json
import math
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack
from statistics import median
from time import perf_counter, sleep

from benchmark import checked_result, connection_options, libpq


def measure(args, options):
    lib = libpq()
    queries = {
        b"frame": (b"SELECT * FROM doom.render_snapshot($1, $2, $3, $4)", 4),
        b"input": (b"SELECT * FROM doom.tick_wad_campaign($1, $2::doom.input_command[])", 2),
    }

    def connect(stack):
        connection = lib.PQconnectdb(options)
        if not connection:
            raise RuntimeError("libpq could not allocate a connection")
        stack.callback(lib.PQfinish, connection)
        if lib.PQstatus(connection) != 0:
            raise RuntimeError(lib.PQerrorMessage(connection).decode().strip())
        for name, (query, count) in queries.items():
            result = lib.PQprepare(connection, name, query, count, None)
            lib.PQclear(checked_result(lib, connection, result, 1))
        return connection

    def call(connection, name, *values):
        params = (C.c_char_p * len(values))(*(str(value).encode() for value in values))
        result = lib.PQexecPrepared(connection, name, len(values), params, None, None, 1)
        result = checked_result(lib, connection, result, 2)
        try:
            if lib.PQntuples(result) != 1 or any(lib.PQgetlength(result, 0, i) != 8 for i in (0, 1)):
                raise RuntimeError(f"{name.decode()} did not return a tagged game clock")
            state = tuple(int.from_bytes(C.string_at(lib.PQgetvalue(result, 0, i), 8), "big", signed=True)
                          for i in (0, 1))
            size = lib.PQgetlength(result, 0, 2)
            if name == b"input":
                if size != 1 or C.c_ubyte.from_address(lib.PQgetvalue(result, 0, 2)).value != 0:
                    raise RuntimeError("benchmark requires an active campaign")
            else:
                rgb_size = values[1] * values[2] * 3
                if args.columns:
                    valid = size == rgb_size
                else:
                    tag = C.c_ubyte.from_address(lib.PQgetvalue(result, 0, 2)).value if size > 1 else -1
                    valid = (tag == 0 and size == rgb_size + 1) or (
                        tag == 1 and size - 1 < rgb_size and (size - 1) % 7 == 0
                    )
                if not valid:
                    raise RuntimeError("unexpected frame packet")
            return state
        finally:
            lib.PQclear(result)

    def frame(connection, game, dimensions):
        return call(connection, b"frame", game, *dimensions, str(args.columns).lower())

    def trial(worker, render_connection, input_connection, game, dimensions, turn):
        previous = worker.submit(frame, render_connection, game, dimensions)
        sleep(args.key_delay_ms / 1000)
        key_time = perf_counter()
        in_flight = not previous.done()
        if input_connection == render_connection:
            previous.result()
        ack = call(input_connection, b"input", game, '{"(0,0,%s,1,false,false)"}' % turn)
        ack_time = perf_counter()
        previous.result()
        current = frame(render_connection, ack[0], dimensions)
        if current != ack:
            raise RuntimeError("the next frame does not match the applied input")
        return ack[0], ((ack_time - key_time) * 1000, (perf_counter() - key_time) * 1000, in_flight)

    with ExitStack() as stack:
        render_connection, input_connection = (connect(stack), connect(stack))
        worker = stack.enter_context(ThreadPoolExecutor(max_workers=1))
        modes = ("serial", "separate")
        games = dict(zip(modes, args.games))
        dimensions = {"serial": tuple(args.size), "separate": tuple(args.split_size or args.size)}
        samples = {mode: [] for mode in modes}
        for sequence in range(args.warmup + args.samples):
            turn = 0.08 if sequence % 2 == 0 else -0.08
            for mode in modes if sequence % 2 == 0 else reversed(modes):
                writer = input_connection if mode == "separate" else render_connection
                games[mode], timing = trial(worker, render_connection, writer, games[mode], dimensions[mode], turn)
                if sequence >= args.warmup:
                    samples[mode].append(timing)

    def p95(values):
        return sorted(values)[math.ceil(0.95 * len(values)) - 1]

    for mode in modes:
        ack, visible, pending = zip(*samples[mode])
        print(json.dumps({
            "mode": mode, "size": dimensions[mode], "samples": len(ack), "columns": args.columns,
            "added_rtt_ms": args.rtt_ms, "bandwidth_mbps": args.mbps, "key_delay_ms": args.key_delay_ms,
            "previous_frame_pending": sum(pending),
            "key_to_ack_p50_ms": round(median(ack), 3), "key_to_ack_p95_ms": round(p95(ack), 3),
            "key_to_frame_p50_ms": round(median(visible), 3), "key_to_frame_p95_ms": round(p95(visible), 3),
        }), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("games", type=int, nargs=2, help="matched campaign game IDs for serial and separate lanes")
    parser.add_argument("--size", type=int, nargs=2, default=(320, 200), metavar=("WIDTH", "HEIGHT"))
    parser.add_argument("--split-size", type=int, nargs=2, metavar=("WIDTH", "HEIGHT"))
    parser.add_argument("--samples", type=int, default=5)
    parser.add_argument("--warmup", type=int, default=2)
    parser.add_argument("--key-delay-ms", type=float, default=120)
    parser.add_argument("--rtt-ms", type=float)
    parser.add_argument("--mbps", type=float)
    parser.add_argument("--columns", action="store_true", help="request column-major RGB packets")
    args = parser.parse_args()
    if len(set(args.games)) != 2 or min(*args.games, *args.size, *(args.split_size or args.size), args.samples) < 1:
        parser.error("positive dimensions, positive sample count and two distinct positive game IDs are required")
    if args.warmup < 0 or any(value is not None and (not math.isfinite(value) or value < 0)
                              for value in (args.key_delay_ms, args.rtt_ms, args.mbps)) or args.mbps == 0:
        parser.error("invalid warmup, key delay, RTT or bandwidth")
    with connection_options(args.rtt_ms, args.mbps) as options:
        measure(args, options)


if __name__ == "__main__":
    main()
