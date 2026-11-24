import asyncio
import hashlib

import psycopg
from psycopg.rows import dict_row

from .automap import Automap


def connect(dsn, *, autocommit=True):
    return psycopg.AsyncConnection.connect(dsn, autocommit=autocommit, row_factory=dict_row)


async def game_query(db, one_way_delay, sql, params, *, binary=False):
    if one_way_delay:
        await asyncio.sleep(one_way_delay)
    result = await db.execute(sql, params, binary=binary)
    if one_way_delay:
        await asyncio.sleep(one_way_delay)
    return result


async def saved_games(dsn):
    async with await connect(dsn) as db:
        result = await db.execute(
            """SELECT g.id, l.name AS map, g.difficulty, g.tic
               FROM doom.games g JOIN doom.levels l ON l.id=g.level
               JOIN doom.actors a ON a.game=g.id AND a.id=-1
               WHERE NOT g.finished AND a.health>0 ORDER BY g.id DESC"""
        )
        return await result.fetchall()


async def prepare_level(db, wad, map_name):
    result = await db.execute(
        "SELECT to_regprocedure('doom.cached_level(bytea,text)') IS NOT NULL AS supported"
    )
    if (await result.fetchone())["supported"]:
        result = await db.execute(
            "SELECT doom.cached_level(%s,%s) AS id", (hashlib.sha256(wad).digest(), map_name)
        )
        level = (await result.fetchone())["id"]
        if level is not None:
            return level
        query = "SELECT doom.prepare_wad(%s,%s) AS id"
    else:
        query = "SELECT doom.load_wad(%s,%s) AS id"
    result = await db.execute(query, (wad, map_name))
    return (await result.fetchone())["id"]


async def open_game(args, wad, level=None, previous_game=None):
    async with await connect(args.dsn, autocommit=False) as db:
        if args.resolution != (160, 100):
            signature = "doom.poll_frame(bigint,bigint,bigint,text,int,int)"
            if args.resolution == (64, 40) and not args.delta:
                signature = "doom.poll_frame_low(bigint,bigint,bigint,text)"
            result = await db.execute("SELECT to_regprocedure(%s) IS NOT NULL AS ready", (signature,))
            if not (await result.fetchone())["ready"]:
                raise ValueError("apply engine/render/lowres.sql to this database to use the requested resolution")
        if args.game is None:
            if level is None:
                level = await prepare_level(db, wad, args.map)
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
            """SELECT g.id AS game, g.*, l.name AS map
               FROM doom.games g JOIN doom.levels l ON l.id=g.level WHERE g.id=%s""",
            (game,),
        )
        state = await result.fetchone()
        if state is None:
            raise ValueError(f"Game {game} does not exist")
        cache_stationary = not args.rife and args.resolution == (160, 100)
        if "cache_stationary" in state and state["cache_stationary"] != cache_stationary:
            await db.execute("UPDATE doom.games SET cache_stationary=%s WHERE id=%s", (cache_stationary, game))
            state["cache_stationary"] = cache_stationary
        state["automap"] = await Automap.load(db, state["level"])
        return state


class Frames:
    def __init__(self, state, delta, resolution=(160, 100)):
        self.game = state["game"]
        self.epoch = state["epoch"]
        self.delta = delta
        self.resolution = resolution
        self.frame = self.palette = self.revision = None
        self.token = self.hashes = None
        self.slot = 0

    async def poll(self, db, one_way_delay):
        self.slot += 1
        params = [self.game, self.epoch, self.slot, self.token]
        source = "doom.poll_tiles" if self.delta else "doom.poll_frame"
        if self.delta:
            params.append(self.hashes)
        if self.resolution == (64, 40) and not self.delta:
            source = "doom.poll_frame_low"
        elif self.resolution != (160, 100):
            params.extend(self.resolution)
        placeholders = ",".join(["%s"] * len(params))
        # keep the hud and world in the same database snapshot
        result = await game_query(
            db,
            one_way_delay,
            f"""SELECT f.*, g.ammo, g.armor, g.keys, g.next_shot, g.secret_exit, a.health
                FROM {source}({placeholders}) f JOIN doom.games g ON g.id=%s
                JOIN doom.actors a ON a.game=g.id AND a.id=-1""",
            [*params, self.game],
            binary=True,
        )
        packet = await result.fetchone()
        revision = packet["palette_revision"]
        palette_changed = self.revision != revision
        if palette_changed:
            result = await game_query(
                db,
                one_way_delay,
                "SELECT doom.frame_palette(%s,%s) AS rgb",
                (self.game, revision),
                binary=True,
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
