import asyncio
import unittest
from functools import partial

from latency_proxy import forward


class LatencyProxyTest(unittest.IsolatedAsyncioTestCase):
    async def transfer(self, payload, delay, *, mbps=None, full_duplex=False):
        uploaded = asyncio.get_running_loop().create_future()

        async def endpoint(reader, writer):
            try:
                if full_duplex:
                    writer.write(payload)
                    await writer.drain()
                    writer.write_eof()
                received = await reader.read()
                uploaded.set_result(received)
                if not full_duplex:
                    writer.write(received)
                    await writer.drain()
            finally:
                writer.close()
                await writer.wait_closed()

        target = await asyncio.start_server(endpoint, "127.0.0.1", 0)
        proxy = await asyncio.start_server(
            partial(
                forward,
                target_host="127.0.0.1",
                target_port=target.sockets[0].getsockname()[1],
                delay=delay,
                mbps=mbps,
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
                response, request = await asyncio.wait_for(asyncio.gather(reader.read(), uploaded), timeout=2)
                self.assertEqual(request, payload)
                return response, clock() - start
            finally:
                writer.close()
                await writer.wait_closed()

    async def test_delays_both_directions_and_preserves_half_close(self):
        payload = b"select 1\x00\xff"
        response, elapsed = await self.transfer(payload, delay=0.04)
        self.assertEqual(response, payload)
        self.assertGreaterEqual(elapsed, 0.075)

    async def test_large_response_does_not_pay_delay_per_chunk(self):
        payload = bytes(range(256)) * 4096
        response, _ = await self.transfer(payload, delay=0.10)
        self.assertEqual(response, payload)

    async def test_bandwidth_adds_one_serialization_time_per_direction(self):
        payload = bytes(range(256)) * 1024
        response, elapsed = await self.transfer(payload, delay=0.04, mbps=10)
        self.assertEqual(response, payload)
        expected = 0.08 + 2 * len(payload) * 8 / 10_000_000
        self.assertGreaterEqual(elapsed, expected - 0.01)
        self.assertLess(elapsed, expected + 0.20)

    async def test_upload_and_download_have_independent_bandwidth(self):
        payload = bytes(range(256)) * 2048
        response, elapsed = await self.transfer(payload, delay=0.01, mbps=8, full_duplex=True)
        self.assertEqual(response, payload)
        one_way = 0.01 + len(payload) * 8 / 8_000_000
        self.assertGreaterEqual(elapsed, one_way - 0.01)
        self.assertLess(elapsed, one_way + 0.35)


if __name__ == "__main__":
    unittest.main()
