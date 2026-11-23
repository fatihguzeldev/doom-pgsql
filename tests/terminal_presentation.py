import asyncio
import math
import threading
import unittest
from importlib.util import find_spec
from time import monotonic
from unittest.mock import patch

from client.art import Image
from client.keyboard import Keyboard
from client.presentation import Presenter, _turn_view


def image(value):
    return Image(1, 1, bytes([value] * 3))


class Model:
    def upscale(self, frame):
        return frame

    def infer_pair(self, a, b):
        return tuple(image(a.rgb[0] + (b.rgb[0] - a.rgb[0]) * i // 5) for i in range(1, 6))


class PresentationTest(unittest.IsolatedAsyncioTestCase):
    @unittest.skipUnless(find_spec("numpy"), "RIFE preview uses NumPy")
    def test_left_turn_moves_a_wall_to_the_right(self):
        wall = b"\x05\x12\x23"
        sky = b"\x03\x06\x09"
        row = sky * 31 + wall * 2 + sky * 31
        view = Image(64, 40, row * 40)
        for angle, direction in ((90, 1), (-90, -1)):
            rgb = _turn_view(view, angle).rgb
            line = rgb[20 * len(row) : 21 * len(row)]
            self.assertGreater(direction * (line.index(wall) // 3 - 31), 0)
            self.assertTrue(line.startswith(sky) and line.endswith(sky))

    async def ready(self, presenter):
        async with asyncio.timeout(2):
            while not presenter._schedule:
                await asyncio.sleep(0.001)

    async def test_new_frames_are_spaced_after_the_second_sql_arrival(self):
        player = Presenter(Model())
        task = asyncio.create_task(player.run())
        with patch("client.presentation.monotonic", return_value=10):
            try:
                player.submit(image(0), 1, 10)
                await self.ready(player)
                self.assertEqual(player.sample(10).image, image(0))
                self.assertEqual(player.sample(10.18).tic, 1)
                with patch("client.presentation.monotonic", return_value=10.2):
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

    async def test_first_frame_after_a_stall_skips_stale_motion(self):
        player = Presenter(Model())
        task = asyncio.create_task(player.run())
        try:
            for tic, arrived in enumerate((10, 10.2, 11.2, 12.2)):
                with patch("client.presentation.monotonic", return_value=arrived):
                    player.submit(image(5 * tic), tic, arrived)
                    await self.ready(player)
                view = player.sample(arrived)
                if tic == 2:
                    self.assertEqual(view.image, image(10))
                    self.assertEqual(view.fraction, 1)
                if tic in (1, 3):
                    self.assertLess(view.fraction, 1)
                player.sample(arrived + 0.2)
        finally:
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)

    async def test_key_preview_reconciles_across_the_yaw_wrap(self):
        player, keys = Presenter(Model()), Keyboard()
        task = asyncio.create_task(player.run())
        a = math.tau - 0.03
        b = 0.06
        with patch("client.presentation._turn_view", side_effect=lambda im, angle: im):
            try:
                player.submit(image(0), 1, 10, a)
                await self.ready(player)
                now = monotonic()
                base = player.sample(now, a)
                keys.feed(b"j", now)
                early = player.sample(now, a, [keys.pending_turn(now)])
                self.assertAlmostEqual(early.yaw - base.yaw, 0.09)
                pending = [keys.sample(now)[2], keys.pending_turn(now)]
                self.assertIs(player.sample(now, a, pending), early)

                player.submit(image(5), 2, 10.2, b)
                await self.ready(player)
                mid = player.sample(monotonic(), b)
                self.assertEqual(mid.fraction, 0.2)
                self.assertAlmostEqual(math.remainder(mid.yaw - b, math.tau), 0)
                end = player.sample(monotonic() + 1, b)
                self.assertAlmostEqual(end.yaw, b)
                self.assertEqual(end.image, image(5))
            finally:
                task.cancel()
                await asyncio.gather(task, return_exceptions=True)

    async def test_reverse_responds_while_the_sql_queue_is_full(self):
        player = Presenter(Model())
        task = asyncio.create_task(player.run())
        with patch("client.presentation._turn_view", side_effect=lambda im, angle: im):
            try:
                player.submit(image(0), 1, 10, 0)
                await self.ready(player)
                now = monotonic()
                turns = [0.09] * 7
                held = player.sample(now, 0, turns)
                reversed_view = player.sample(now, 0, [*turns, -0.09])
                self.assertAlmostEqual(held.yaw - reversed_view.yaw, 0.09)
                player.reset()
                self.assertIsNone(player.sample(now, 0, turns))
            finally:
                task.cancel()
                await asyncio.gather(task, return_exceptions=True)
