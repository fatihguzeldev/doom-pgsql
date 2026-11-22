import asyncio
import unittest
from functools import partial

from latency_proxy import forward


class LatencyProxyTest(unittest.IsolatedAsyncioTestCase):
    async def forward_to_echo(self, payload, delay):
        async def echo(reader, writer):
            try:
                writer.write(await reader.read())
                await writer.drain()
            finally:
                writer.close()
                await writer.wait_closed()

        target = await asyncio.start_server(echo, "127.0.0.1", 0)
        proxy = await asyncio.start_server(
            partial(
                forward,
                target_host="127.0.0.1",
                target_port=target.sockets[0].getsockname()[1],
                delay=delay,
            ),
            "127.0.0.1",
            0,
        )
        async with target, proxy:
            reader, writer = await asyncio.open_connection(
                "127.0.0.1", proxy.sockets[0].getsockname()[1]
            )
            try:
                clock = asyncio.get_running_loop().time
                start = clock()
                writer.write(payload)
                await writer.drain()
                writer.write_eof()
                response = await asyncio.wait_for(reader.read(), timeout=2)
                return response, clock() - start
            finally:
                writer.close()
                await writer.wait_closed()

    async def test_delays_both_directions_and_preserves_half_close(self):
        payload = b"select 1\x00\xff"
        response, elapsed = await self.forward_to_echo(payload, delay=0.04)
        self.assertEqual(response, payload)
        self.assertGreaterEqual(elapsed, 0.075)

    async def test_large_response_does_not_pay_delay_per_chunk(self):
        payload = bytes(range(256)) * 4096
        response, _ = await self.forward_to_echo(payload, delay=0.10)
        self.assertEqual(response, payload)


if __name__ == "__main__":
    unittest.main()
