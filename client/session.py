import asyncio
from time import monotonic

import psycopg
from psycopg.types.json import Jsonb

from .art import world_image
from .database import Frames, connect, game_query
from .presentation import Presenter, View


class Session:
    def __init__(self, args, state, keys, engine=None):
        self.dsn, self.state, self.keys = args.dsn, state, keys
        self.one_way_delay = args.rtt_ms / 2000
        self.frames = Frames(state, args.delta, args.resolution)
        self.presenter = Presenter(engine) if engine is not None else None
        self.view = None
        self.pose = None
        self.active = asyncio.Event()
        self.active.set()
        self.pending = asyncio.Queue(maxsize=2)
        self.turns = {}
        self.status = None
        self.ended = False
        self.last_shot = None
        self._next_shot = state["next_shot"]
        self.predict_turn = args.predict_turn

    def sample_view(self, now):
        if self.presenter is None:
            turn = sum(self.turns.values()) if self.predict_turn else 0
            return self.view, turn
        yaw = self.pose[2] if self.pose is not None else None
        turns = (*self.turns.values(), self.keys.pending_turn(now))
        return self.presenter.sample(now, yaw, turns), 0

    def pause(self):
        self.active.clear()
        if self.presenter is not None:
            self.presenter.reset()

    def _refresh_presenter(self):
        if self.presenter is not None:
            self.presenter.reset()
            self.frames.token = None

    def resume(self):
        self._refresh_presenter()
        self.active.set()

    async def submit(self):
        tic = self.state["tic"] + 1
        batch = []
        while True:
            try:
                async with await connect(self.dsn) as db:
                    while True:
                        if not batch:
                            batch.append(await self.pending.get())
                            while not self.pending.empty():
                                batch.append(self.pending.get_nowait())
                        # retry the same tic range if the commit outcome is unknown
                        await game_query(
                            db,
                            self.one_way_delay,
                            "CALL doom.submit(%s,%s,%s,%s)",
                            (self.state["game"], self.state["epoch"], tic, Jsonb(batch)),
                        )
                        tic += len(batch)
                        batch.clear()
            except (
                psycopg.OperationalError,
                psycopg.errors.DeadlockDetected,
                psycopg.errors.SerializationFailure,
            ):
                await asyncio.sleep(0.1)

    async def capture(self):
        tic = self.state["tic"]
        while True:
            await self.active.wait()
            start = monotonic()
            command = self.keys.sample(start)
            tic += 1
            if (self.predict_turn or self.presenter is not None) and command[2]:
                self.turns[tic] = command[2]
            await self.pending.put(command)
            await asyncio.sleep(max(0, 1 / 35 - (monotonic() - start)))

    async def receive(self, sound):
        while True:
            try:
                async with await connect(self.dsn, application_name=f"doom-pgsql/{self.frames.game}") as db:
                    while True:
                        await self.active.wait()
                        start = monotonic()
                        prior_revision = self.frames.revision
                        packet, changed = await self.frames.poll(db, self.one_way_delay)
                        if packet is None:
                            continue
                        now = monotonic()
                        self.pose = (packet["camera_x"], packet["camera_y"], packet["yaw"])
                        image = world_image(self.frames.frame, self.frames.palette) if changed else self.view.image
                        self.view = View(image, packet["tic"], 1, packet["yaw"])
                        if self.presenter is not None:
                            if self.frames.revision != prior_revision:
                                self.presenter.reset()
                            self.presenter.submit(image, packet["tic"], now, packet["yaw"])
                        for tic in tuple(self.turns):
                            if tic <= packet["tic"]:
                                del self.turns[tic]
                        self.status = {
                            k: packet[k]
                            for k in (
                                "ammo",
                                "health",
                                "armor",
                                "keys",
                                "next_shot",
                                "tic",
                                "finished",
                                "secret_exit",
                            )
                        }
                        if packet["next_shot"] > self._next_shot:
                            self.last_shot = now
                            sound.effect("DSPISTOL")
                        self._next_shot = packet["next_shot"]
                        for batch in packet.get("sounds", ()):
                            for thing, event in batch:
                                sound.monster(thing, event)
                        if packet["finished"] or packet["health"] <= 0:
                            self.ended = True
                            self.active.clear()
                            self.keys.menu_keys.put_nowait("end")
                        await asyncio.sleep(max(0, 1 / 30 - (monotonic() - start)))
            except psycopg.OperationalError:
                self._refresh_presenter()
                await asyncio.sleep(0.1)
