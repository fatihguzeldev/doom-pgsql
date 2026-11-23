"""Schedule live interpolation from SQL frames as they arrive."""

import asyncio
from collections import deque
from dataclasses import dataclass
from time import monotonic

from .art import Image


@dataclass(frozen=True)
class View:
    image: Image
    tic: int
    fraction: float


class Presenter:
    def __init__(self, engine):
        self.engine = engine
        self._ready = asyncio.Event()
        self._generation = 0
        self._latest = None
        self._schedule = deque()
        self._current = None
        self._shown = deque()

    def reset(self):
        self._generation += 1
        self._latest = self._current = None
        self._ready.clear()
        self._schedule.clear()
        self._shown.clear()

    def submit(self, image, tic, arrived):
        # Keep one pending SQL frame if inference falls behind the database.
        self._latest = (image, tic, arrived)
        self._ready.set()

    async def run(self):
        previous = None
        generation = None
        while True:
            await self._ready.wait()
            self._ready.clear()
            current = self._latest
            if current is None:
                continue
            image, tic, arrived = current
            if generation != self._generation:
                previous = None
                generation = self._generation
            if previous is None:
                views = (await self._infer(self.engine.upscale, image),)
                interval = 0
            elif image.rgb == previous[0].rgb:
                previous = current
                continue
            else:
                views = await self._infer(self.engine.infer_pair, previous[0], image)
                # Catch up after a SQL stall instead of replaying its entire duration.
                interval = min(0.2, arrived - previous[2]) / len(views)
            if generation != self._generation:
                continue
            previous = current
            self._schedule.clear()
            start = monotonic()
            for i, view in enumerate(views):
                self._schedule.append((start + i * interval, View(view, tic, (i + 1) / len(views))))

    async def _infer(self, fn, *args):
        job = asyncio.create_task(asyncio.to_thread(fn, *args))
        try:
            return await asyncio.shield(job)
        except asyncio.CancelledError:
            # Another game can reuse the same model as soon as this worker exits.
            await job
            raise

    def sample(self, now):
        current = self._current
        while self._schedule and self._schedule[0][0] <= now:
            _, current = self._schedule.popleft()
        if current is not self._current:
            if self._current is None or current.image.rgb != self._current.image.rgb:
                self._shown.append(now)
            self._current = current
        return current

    def fps(self, now):
        while self._shown and self._shown[0] <= now - 1:
            self._shown.popleft()
        return len(self._shown)
