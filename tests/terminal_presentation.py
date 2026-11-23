import asyncio
import threading
import unittest
from time import monotonic
from unittest.mock import patch

from examples.terminal.art import Image
from examples.terminal.presentation import Presenter


def image(value):
    return Image(1, 1, bytes([value] * 3))


class Model:
    def upscale(self, frame):
        return frame

    def infer_pair(self, a, b):
        return tuple(image(a.rgb[0] + (b.rgb[0] - a.rgb[0]) * i // 5) for i in range(1, 6))


class PresentationTest(unittest.IsolatedAsyncioTestCase):
    async def ready(self, presenter):
        async with asyncio.timeout(2):
            while not presenter._schedule:
                await asyncio.sleep(0.001)

    async def test_new_frames_are_spaced_after_the_second_sql_arrival(self):
        player = Presenter(Model())
        task = asyncio.create_task(player.run())
        with patch("examples.terminal.presentation.monotonic", return_value=10):
            try:
                player.submit(image(0), 1, 10)
                await self.ready(player)
                self.assertEqual(player.sample(10).image, image(0))
                self.assertEqual(player.sample(10.18).tic, 1)
                with patch("examples.terminal.presentation.monotonic", return_value=10.2):
                    player.submit(image(5), 2, 10.2)
                    await self.ready(player)
                self.assertEqual(player.sample(10.199).tic, 1)
                for i in range(5):
                    at = 10.201 + i * 0.04
                    self.assertEqual(player.sample(at).image, image(i + 1))
                    self.assertEqual(player.fps(at), i + 2)
                self.assertEqual(player.sample(12).fraction, 1)
                self.assertEqual(player.fps(12), 0)
            finally:
                task.cancel()
                await asyncio.gather(task, return_exceptions=True)

    async def test_pause_discards_a_pair_still_being_inferred(self):
        started, finish = threading.Event(), threading.Event()

        class Slow(Model):
            def infer_pair(self, a, b):
                started.set()
                finish.wait(2)
                return super().infer_pair(a, b)

        player = Presenter(Slow())
        task = asyncio.create_task(player.run())
        try:
            player.submit(image(0), 1, 0)
            await self.ready(player)
            player.sample(monotonic())
            player.submit(image(5), 2, 0.2)
            self.assertTrue(await asyncio.to_thread(started.wait, 2))
            player.reset()
            player.submit(image(9), 3, 0.3)
            finish.set()
            await self.ready(player)
            now = monotonic()
            self.assertEqual(player.sample(now).image, image(9))
            self.assertEqual(player.fps(now), 1)
        finally:
            finish.set()
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
