import asyncio
import math
from collections import deque
from dataclasses import dataclass
from functools import lru_cache
from time import monotonic

from .art import Image


@dataclass(frozen=True)
class View:
    image: Image
    tic: int
    fraction: float
    yaw: float | None = None


class FrameRate:
    def __init__(self):
        self._start = None
        self._count = 0
        self._view = None
        self._turn = 0
        self._rate = None

    def sample(self, now, view, turn):
        if self._start is None:
            self._start = now
        elif view is not self._view or turn != self._turn:
            self._count += 1
        self._view, self._turn = view, turn
        elapsed = now - self._start
        if elapsed >= 1:
            self._rate = self._count / elapsed
            self._start, self._count = now, 0
        return self._rate


# two input tics limit the exposed edge during a turn
MAX_PREVIEW = 0.18


def _clamp_turn(turn):
    return max(-MAX_PREVIEW, min(MAX_PREVIEW, turn))


@lru_cache(maxsize=16)
def _turn_pixels(width, height, milliradians):
    import numpy as np

    angle = milliradians / 1000
    c, s = math.cos(angle), math.sin(angle)
    ray = (np.arange(width) + 0.5) * (2 / width) - 1
    depth = c + ray * s
    x = np.floor(width * (1 + (ray * c - s) / depth) / 2).astype(np.intp)
    rows = np.arange(height)[:, None] + 0.5 - height / 2
    y = np.floor(height / 2 + rows / depth).astype(np.intp)
    return y.clip(0, height - 1) * width + x.clip(0, width - 1)


def _turn_view(image, milliradians):
    import numpy as np

    pixels = np.frombuffer(image.rgb, np.uint8).reshape(-1, 3)
    indices = _turn_pixels(image.width, image.height, milliradians)
    return Image(image.width, image.height, pixels[indices].tobytes())


class Presenter:
    def __init__(self, engine):
        self.engine = engine
        self._ready = asyncio.Event()
        self._generation = 0
        self._latest = None
        self._schedule = deque()
        self._current = None
        self._displayed = None
        self._turn = 0

    def reset(self):
        self._generation += 1
        self._latest = self._current = self._displayed = None
        self._turn = 0
        self._ready.clear()
        self._schedule.clear()

    def submit(self, image, tic, arrived, yaw=None):
        self._latest = (image, tic, arrived, yaw)
        self._ready.set()

    async def run(self):
        previous = None
        last_gap = 0.0
        generation = None
        while True:
            await self._ready.wait()
            self._ready.clear()
            current = self._latest
            if current is None:
                continue
            image, tic, arrived, yaw = current
            if generation != self._generation:
                previous = None
                last_gap = 0.0
                generation = self._generation
            gap = arrived - previous[2] if previous is not None else 0.0
            stalled = gap > max(0.5, 2 * last_gap)
            last_gap = gap
            if previous is not None and previous[0].rgb == image.rgb and previous[3] == yaw:
                previous = current
                # reuse the finished frame without interrupting a pair still on screen
                if not self._schedule and self._current is not None:
                    repeat = View(self._current.image, tic, 1, yaw)
                    self._schedule.append((arrived, repeat))
                continue
            start_yaw = previous[3] if previous is not None else yaw
            if previous is None or stalled or image.rgb == previous[0].rgb:
                views = (await self._infer(self.engine.upscale, image),)
                interval = 0
            else:
                views = await self._infer(self.engine.infer_pair, previous[0], image)
                interval = min(0.2, gap) / len(views)
            if generation != self._generation:
                continue
            previous = current
            self._schedule.clear()
            start = monotonic()
            for i, view in enumerate(views):
                fraction = (i + 1) / len(views)
                heading = yaw
                if fraction < 1 and yaw is not None and start_yaw is not None:
                    heading = start_yaw + fraction * math.remainder(yaw - start_yaw, math.tau)
                self._schedule.append((start + i * interval, View(view, tic, fraction, heading)))

    async def _infer(self, fn, *args):
        job = asyncio.create_task(asyncio.to_thread(fn, *args))
        try:
            return await asyncio.shield(job)
        except asyncio.CancelledError:
            # wait for inference before the next game reuses the model
            await job
            raise

    def sample(self, now, confirmed_yaw=None, turns=()):
        current = self._current
        while self._schedule and self._schedule[0][0] <= now:
            _, current = self._schedule.popleft()
        if current is None:
            return None
        offset = 0.0
        if current.yaw is not None and confirmed_yaw is not None:
            offset = _clamp_turn(math.remainder(confirmed_yaw - current.yaw, math.tau))
            for turn in turns:
                # clamp each step so a reversal takes effect immediately
                offset = _clamp_turn(offset + turn)
        milliradians = round(1000 * offset)
        if current is not self._current or milliradians != self._turn:
            view = current
            if milliradians:
                image = _turn_view(current.image, milliradians)
                view = View(image, current.tic, current.fraction, current.yaw + milliradians / 1000)
            self._current = current
            self._displayed = view
            self._turn = milliradians
        return self._displayed
