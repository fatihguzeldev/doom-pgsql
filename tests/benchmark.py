"""Measure persistent PostgreSQL requests with binary results and standard PG connection variables."""

import argparse
import ctypes as C
import ctypes.util
import json
import math
import os
import subprocess
import sys
from pathlib import Path
from statistics import mean, median
from time import perf_counter


def libpq():
    library = ctypes.util.find_library("pq")
    if library is None:
        directory = Path(subprocess.check_output(["pg_config", "--libdir"], text=True).strip())
        library = next(path for path in (directory / "libpq.dylib", directory / "libpq.so") if path.exists())
    lib = C.CDLL(str(library))
    pointer, string, integer = C.c_void_p, C.c_char_p, C.c_int
    signatures = {
        "PQconnectdb": (pointer, string),
        "PQstatus": (integer, pointer),
        "PQfinish": (None, pointer),
        "PQerrorMessage": (string, pointer),
        "PQprepare": (pointer, pointer, string, string, integer, pointer),
        "PQexecPrepared": (pointer, pointer, string, integer, C.POINTER(string), pointer, pointer, integer),
        "PQresultStatus": (integer, pointer),
        "PQresultErrorMessage": (string, pointer),
        "PQntuples": (integer, pointer),
        "PQgetlength": (integer, pointer, integer, integer),
        "PQclear": (None, pointer),
    }
    for name, (result, *args) in signatures.items():
        function = getattr(lib, name)
        function.restype = result
        function.argtypes = args
    return lib


def checked_result(lib, connection, result, expected_status):
    if not result:
        raise RuntimeError(lib.PQerrorMessage(connection).decode().strip())
    if lib.PQresultStatus(result) != expected_status:
        message = lib.PQresultErrorMessage(result).decode().strip()
        lib.PQclear(result)
        raise RuntimeError(message)
    return result


def measure(args, connection_options=b""):
    lib = libpq()
    game = str(args.game).encode()
    width = str(args.width).encode()
    height = str(args.height).encode()
    ticks = str(args.ticks).encode()
    fire = b", p_fire => true" if args.fire else b""
    queries = {
        "noop": (b"SELECT 1", lambda _: [], 4),
        "tick": (b"SELECT doom.tick($1, $2, 0, 0, $3" + fire + b")", lambda axis: [game, axis, ticks], 8),
        "render": (b"SELECT doom.render($1, $2, $3)", lambda _: [game, width, height], args.width * args.height * 3),
        "render_spans": (b"SELECT doom.render_spans($1, $2, $3)", lambda _: [game, width, height], None),
        "step": (b"SELECT doom.step($1, $2, $3, $4, 0, 0, $5" + fire + b")",
                 lambda axis: [game, width, height, axis, ticks], args.width * args.height * 3),
        "step_spans": (b"SELECT doom.step_spans($1, $2, $3, $4, 0, 0, $5" + fire + b")",
                       lambda axis: [game, width, height, axis, ticks], None),
    }
    operations = ("tick", "render") if args.mode == "split" else (args.mode,)
    connection = lib.PQconnectdb(connection_options)
    if not connection:
        raise RuntimeError("libpq could not allocate a connection")

    try:
        if lib.PQstatus(connection) != 0:
            raise RuntimeError(lib.PQerrorMessage(connection).decode().strip())
        for name in operations:
            query, parameters, _ = queries[name]
            result = lib.PQprepare(connection, name.encode(), query, len(parameters(b"0")), None)
            lib.PQclear(checked_result(lib, connection, result, 1))

        samples = []
        payload_sizes = []
        elapsed = 0.0
        for i in range(args.warmup + args.samples):
            axis = b"0.125" if i % 2 == 0 else b"-0.125"
            sample_bytes = 0
            started = perf_counter()
            for name in operations:
                _, parameters, size = queries[name]
                values = parameters(axis)
                params = (C.c_char_p * len(values))(*values)
                result = lib.PQexecPrepared(connection, name.encode(), len(values), params, None, None, 1)
                result = checked_result(lib, connection, result, 2)
                try:
                    if lib.PQntuples(result) != 1:
                        raise RuntimeError(f"{name} did not return one result row")
                    result_bytes = lib.PQgetlength(result, 0, 0)
                    if size is None and (result_bytes == 0 or result_bytes % 7):
                        raise RuntimeError(f"{name} did not return a nonempty sequence of 7-byte RGB changes")
                    if size is not None and result_bytes != size:
                        raise RuntimeError(f"{name} did not return the expected {size}-byte result")
                    sample_bytes += result_bytes
                finally:
                    lib.PQclear(result)
            duration = perf_counter() - started
            if i >= args.warmup:
                elapsed += duration
                samples.append(duration * 1000)
                payload_sizes.append(sample_bytes)

        return {
            "mode": args.mode,
            "fire": args.fire,
            "samples": args.samples,
            "added_rtt_ms": args.rtt_ms,
            "bandwidth_mbps": args.mbps,
            "round_trips_per_sample": len(operations),
            "payload_bytes": mean(payload_sizes),
            "median_ms": round(median(samples), 3),
            "p95_ms": round(sorted(samples)[math.ceil(0.95 * len(samples)) - 1], 3),
            "samples_per_second": round(len(samples) / elapsed, 3),
        }
    finally:
        lib.PQfinish(connection)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("noop", "tick", "render", "render_spans", "step", "step_spans", "split"))
    parser.add_argument("--game", type=int, default=1)
    parser.add_argument("--width", type=int, default=320)
    parser.add_argument("--height", type=int, default=200)
    parser.add_argument("--ticks", type=int, default=1)
    parser.add_argument("--warmup", type=int, default=10)
    parser.add_argument("--samples", type=int, default=100)
    parser.add_argument("--fire", action="store_true", help="fire once per simulation request")
    parser.add_argument("--rtt-ms", type=float, help="add this TCP round-trip delay using the local proxy")
    parser.add_argument("--mbps", type=float, help="limit TCP throughput in each direction using the local proxy")
    args = parser.parse_args()
    if args.warmup < 0 or min(args.samples, args.width, args.height, args.ticks) < 1:
        parser.error("sample count, width, height and tick count must be positive")
    if args.fire and args.mode not in {"tick", "step", "step_spans", "split"}:
        parser.error("--fire requires a simulation mode")
    if args.mbps is not None:
        if args.mbps <= 0 or not math.isfinite(args.mbps):
            parser.error("bandwidth must be finite and positive")
        if args.rtt_ms is None:
            args.rtt_ms = 0.0
    if args.rtt_ms is None:
        print(json.dumps(measure(args)))
        return
    if args.rtt_ms < 0 or not math.isfinite(args.rtt_ms):
        parser.error("RTT must be finite and nonnegative")

    command = [sys.executable, "-B", str(Path(__file__).with_name("latency_proxy.py")),
               "--target-host", os.environ.get("PGHOSTADDR") or os.environ.get("PGHOST", "127.0.0.1"),
               "--target-port", os.environ.get("PGPORT", "5432"), "--rtt-ms", str(args.rtt_ms)]
    if args.mbps is not None:
        command.extend(("--mbps", str(args.mbps)))
    with subprocess.Popen(command, stdout=subprocess.PIPE, text=True) as proxy:
        try:
            port = proxy.stdout.readline().strip()
            if not port.isdecimal():
                raise RuntimeError("latency proxy could not start")
            print(json.dumps(measure(args, f"hostaddr=127.0.0.1 port={port}".encode())))
        finally:
            if proxy.poll() is None:
                proxy.terminate()


if __name__ == "__main__":
    main()
