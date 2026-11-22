"""Simulate fixed RTT and optional TCP bandwidth for a local benchmark with Python 3.11+."""

import argparse
import asyncio
import math
from contextlib import suppress
from functools import partial


CHUNK_SIZE = 64 * 1024
PENDING_CHUNKS = 64


async def receive(reader, pending, delay):
    clock = asyncio.get_running_loop().time
    while True:
        data = await reader.read(CHUNK_SIZE)
        await pending.put((clock() + delay, data))
        if not data:
            return


async def send(writer, pending, mbps):
    clock = asyncio.get_running_loop().time
    seconds_per_byte = 8e-6 / mbps if mbps is not None else 0
    serialized_until = 0
    while True:
        ready_at, data = await pending.get()
        # Each direction has its own timeline. Later chunks queue behind bytes
        # already on the link without paying propagation delay again.
        ready_at = max(ready_at, serialized_until) + len(data) * seconds_per_byte
        serialized_until = ready_at
        wait = ready_at - clock()
        if wait > 0:
            await asyncio.sleep(wait)
        if not data:
            writer.write_eof()
            return
        writer.write(data)
        await writer.drain()


async def forward(client_reader, client_writer, *, target_host, target_port, delay, mbps=None):
    target_writer = None
    try:
        target_reader, target_writer = await asyncio.open_connection(target_host, target_port)
        async with asyncio.TaskGroup() as tasks:
            for reader, writer in ((client_reader, target_writer), (target_reader, client_writer)):
                # Timestamp on receipt so consecutive chunks wait concurrently.
                pending = asyncio.Queue(maxsize=PENDING_CHUNKS)
                tasks.create_task(receive(reader, pending, delay))
                tasks.create_task(send(writer, pending, mbps))
    except* OSError:
        pass
    finally:
        writers = (client_writer,) if target_writer is None else (client_writer, target_writer)
        for writer in writers:
            writer.close()
        for writer in writers:
            with suppress(OSError):
                await writer.wait_closed()


async def serve(listen_port, target_host, target_port, round_trip_ms, mbps):
    handler = partial(
        forward, target_host=target_host, target_port=target_port, delay=round_trip_ms / 2000, mbps=mbps
    )
    server = await asyncio.start_server(handler, "127.0.0.1", listen_port)
    async with server:
        print(server.sockets[0].getsockname()[1], flush=True)
        await server.serve_forever()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--listen-port", type=int, default=0, help="loopback port; 0 picks a free port")
    parser.add_argument("--target-host", default="127.0.0.1")
    parser.add_argument("--target-port", type=int, required=True)
    parser.add_argument("--rtt-ms", type=float, required=True, help="total added milliseconds across both directions")
    parser.add_argument("--mbps", type=float, help="megabits per second in each direction (default: unlimited)")
    args = parser.parse_args()
    if not 0 <= args.listen_port <= 65535 or not 1 <= args.target_port <= 65535:
        parser.error("ports must be in 0..65535, with zero allowed only for --listen-port")
    if args.rtt_ms < 0 or not math.isfinite(args.rtt_ms):
        parser.error("--rtt-ms must be finite and nonnegative")
    if args.mbps is not None and (
        args.mbps <= 0 or not math.isfinite(args.mbps) or not math.isfinite(CHUNK_SIZE * 8e-6 / args.mbps)
    ):
        parser.error("--mbps must be finite and positive, with a finite chunk transmission time")

    try:
        asyncio.run(serve(args.listen_port, args.target_host, args.target_port, args.rtt_ms, args.mbps))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
