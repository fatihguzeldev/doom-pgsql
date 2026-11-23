"""Drive the SQL simulation and read its world frames from independent connections."""

import asyncio
from collections import deque
from time import monotonic

import psycopg
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb


def connect(dsn, *, autocommit=True):
    return psycopg.AsyncConnection.connect(dsn, autocommit=autocommit, row_factory=dict_row)


async def saved_games(dsn):
    async with await connect(dsn) as db:
        result = await db.execute(
            """SELECT g.id, l.name AS map, g.difficulty, g.tic
               FROM doom.games g JOIN doom.levels l ON l.id=g.level
               JOIN doom.actors a ON a.game=g.id AND a.id=-1
               WHERE NOT g.finished AND a.health>0 ORDER BY g.id DESC"""
        )
        return await result.fetchall()


async def open_game(args, wad, level=None, previous_game=None):
    async with await connect(args.dsn, autocommit=False) as db:
        if args.game is None:
            if level is None:
                result = await db.execute("SELECT doom.load_wad(%s,%s) AS id", (wad, args.map))
                level = (await result.fetchone())["id"]
            result = await db.execute("SELECT game_id FROM doom.new_game(%s,%s)", (level, args.skill))
            game = (await result.fetchone())["game_id"]
            if previous_game is not None:
                await db.execute(
                    """UPDATE doom.games g SET ammo=p.ammo, armor=p.armor
                       FROM doom.games p WHERE g.id=%s AND p.id=%s""",
                    (game, previous_game),
                )
                await db.execute(
                    """UPDATE doom.actors a SET health=p.health FROM doom.actors p
                       WHERE a.game=%s AND p.game=%s AND a.id=-1 AND p.id=-1""",
                    (game, previous_game),
                )
        else:
            game = args.game
        result = await db.execute(
            """SELECT g.id AS game, g.level, g.epoch, g.tic, g.difficulty, g.next_shot, l.name AS map
               FROM doom.games g JOIN doom.levels l ON l.id=g.level WHERE g.id=%s""",
            (game,),
        )
        state = await result.fetchone()
        if state is None:
            raise ValueError(f"Game {game} does not exist")
        return state


class Frames:
    def __init__(self, state, delta):
        self.game = state["game"]
        self.epoch = state["epoch"]
        self.delta = delta
        self.frame = self.palette = self.revision = None
        self.token = self.hashes = None
        self.slot = 0

    async def poll(self, db):
        self.slot += 1
        params = [self.game, self.epoch, self.slot, self.token]
        if self.delta:
            source = "doom.poll_tiles(%s,%s,%s,%s,%s)"
            params.append(self.hashes)
        else:
            source = "doom.poll_frame(%s,%s,%s,%s)"
        # Read the HUD and the world from the same database snapshot.
        result = await db.execute(
            f"""SELECT f.*, g.ammo, g.armor, g.keys, g.next_shot, g.secret_exit, a.health
                FROM {source} f JOIN doom.games g ON g.id=%s
                JOIN doom.actors a ON a.game=g.id AND a.id=-1""",
            [*params, self.game],
            binary=True,
        )
        packet = await result.fetchone()
        revision = packet["palette_revision"]
        palette_changed = self.revision != revision
        if palette_changed:
            result = await db.execute(
                "SELECT doom.frame_palette(%s,%s) AS rgb", (self.game, revision), binary=True
            )
            palette = (await result.fetchone())["rgb"]
            if palette is None:
                self.token = self.hashes = None
                return None, False
            self.revision, self.palette = revision, palette

        changed = packet["pixels"] is not None
        if self.delta:
            self.hashes = packet["hashes"]
            changed = bool(packet["tiles"])
            if changed:
                for channel in ("pixels", "shades"):
                    data = bytearray(
                        self.frame[channel] if self.frame else packet["width"] * packet["height"]
                    )
                    strip = 8 * packet["height"]
                    for i, tile in enumerate(packet["tiles"]):
                        data[tile * strip : (tile + 1) * strip] = packet[channel][i * strip : (i + 1) * strip]
                    packet[channel] = data
        if changed:
            self.frame = packet
        self.token = packet["token"]
        return packet, changed or palette_changed


class Session:
    def __init__(self, args, state, keys):
        self.dsn, self.state, self.keys = args.dsn, state, keys
        self.frames = Frames(state, args.delta)
        self.active = asyncio.Event()
        self.active.set()
        self.pending = asyncio.Queue(maxsize=2)
        self.turns = {}
        self.status = None
        self.ended = False
        self._arrivals = deque()
        self.last_shot = None
        self._next_shot = state["next_shot"]
        self.predict_turn = args.predict_turn

    def fps(self, now):
        while self._arrivals and self._arrivals[0] <= now - 1:
            self._arrivals.popleft()
        return len(self._arrivals)

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
                        # Reuse the same first tic and payload after an uncertain commit.
                        await db.execute(
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
            if self.predict_turn and command[2]:
                self.turns[tic] = command[2]
            await self.pending.put(command)
            await asyncio.sleep(max(0, 1 / 35 - (monotonic() - start)))

    async def receive(self, on_shot):
        while True:
            try:
                async with await connect(self.dsn) as db:
                    while True:
                        await self.active.wait()
                        start = monotonic()
                        packet, changed = await self.frames.poll(db)
                        if packet is None:
                            continue
                        now = monotonic()
                        if changed:
                            self._arrivals.append(now)
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
                            on_shot()
                        self._next_shot = packet["next_shot"]
                        if packet["finished"] or packet["health"] <= 0:
                            self.ended = True
                            self.active.clear()
                            self.keys.menu_keys.put_nowait("end")
                        await asyncio.sleep(max(0, 1 / 30 - (monotonic() - start)))
            except psycopg.OperationalError:
                await asyncio.sleep(0.1)
