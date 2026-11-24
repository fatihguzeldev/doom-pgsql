import argparse
import asyncio
import math
import os
import re
import sys
from pathlib import Path
from time import monotonic

import psycopg

if not __package__:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from client.art import Art
from client.database import open_game
from client.display import Display
from client.keyboard import Keyboard, screen
from client.menu import new_game_menu, pause_menu
from client.presentation import FrameRate
from client.session import Session
from client.sound import game_audio, map_track
from client.widgets import LOGO_HZ

BUNDLED_WAD = Path(__file__).resolve().parents[1] / "assets" / "doom1.wad"


async def first(*coroutines):
    tasks = [asyncio.create_task(coro) for coro in coroutines]
    try:
        done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        results = [task.result() for task in tasks if task in done]
        return results[0]
    finally:
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)


async def loading_screen(display, target, started):
    while True:
        now = monotonic()
        display.loading(target, int(now - started), int(now * LOGO_HZ))
        await asyncio.sleep(1 / LOGO_HZ)


async def play_session(session, display, keys, maps, started):
    period = 1 / 60 if session.presenter is not None else 1 / 35
    counter = FrameRate()
    while True:
        now = monotonic()
        view, turn = session.sample_view(now)
        if view is not None and session.status:
            age = now - session.last_shot if session.last_shot is not None else None
            if age is not None and age >= 8 / 35:
                age = None
            display.paint(
                view.image,
                dict(session.status, auto_walk=keys.auto_walk),
                turn,
                counter.sample(now, view, turn),
                automap=session.state.get("automap"),
                pose=session.pose,
                shot_age=age,
                phase=int(now * LOGO_HZ),
                lit_keys=keys.lit_keys(now),
            )
        else:
            display.loading(session.state["map"], int(now - started), int(now * LOGO_HZ))
        try:
            key = await asyncio.wait_for(keys.menu_keys.get(), max(0.001, period - (monotonic() - now)))
        except TimeoutError:
            continue
        if key not in ("esc", "end"):
            continue
        session.pause()
        action = await pause_menu(session, keys, display, maps)
        if action is None:
            continue
        if action != "resume":
            return action
        keys.set_menu(False)
        counter = FrameRate()
        session.resume()


async def play(args, keys):
    path = args.wad or BUNDLED_WAD
    wad = path.read_bytes() if path.exists() or args.game is None else b""
    art = Art.from_bytes(wad)
    display = Display(art)
    engine = None
    if args.rife:
        from client.rife import Rife

        engine = await first(loading_screen(display, "RIFE", monotonic()), asyncio.to_thread(Rife))
    maps = art.maps
    if args.game is None and args.map and maps and args.map not in maps:
        raise ValueError(f"Map {args.map} not found in {path.name}")
    if args.map is None:
        preferred = "E1M7" if args.wad is None else "E1M1"
        args.map = preferred if preferred in maps else next(iter(maps), "E1M1")
    if args.map not in maps:
        maps = (*maps, args.map)
    show_menu = args.game is None
    level = None
    previous_game = None
    async with game_audio(art, args.mute) as sound:
        while not keys.quit.is_set():
            if show_menu:
                await sound.music("D_INTRO" if "D_INTRO" in art.music else "D_DM2TTL")
                if not await new_game_menu(args, maps, display, keys):
                    return
            started = monotonic()
            target = args.map if args.game is None else f"game #{args.game}"
            state = await first(
                loading_screen(display, target, started),
                open_game(args, wad, level, previous_game),
            )
            args.map, args.skill = state["map"], state["difficulty"]
            await sound.music(map_track(args.map, art.music))
            if args.map not in maps:
                maps = (*maps, args.map)
            keys.set_menu(False)
            session = Session(args, state, keys, engine)
            tasks = [
                play_session(session, display, keys, maps, started),
                session.capture(),
                session.submit(),
                session.receive(lambda: sound.effect("DSPISTOL")),
            ]
            if session.presenter is not None:
                tasks.append(session.presenter.run())
            action = await first(*tasks)
            args.game = None
            if action == "quit":
                return
            show_menu = action == "menu"
            level = state["level"] if action == "restart" else None
            previous_game = None
            if not show_menu and level is None:
                args.map = action
                previous_game = state["game"]


def local_rtt_ms(dsn, override):
    if dsn is not None:
        return 0.0
    rtt = float(override if override is not None else os.environ.get("DOOM_RTT_MS", "0"))
    if not math.isfinite(rtt) or rtt < 0:
        raise ValueError("expected a finite, nonnegative number")
    return rtt


def render_resolution(dsn, override, rife):
    size = override
    if size is None:
        size = os.environ.get("DOOM_RIFE_RESOLUTION", "160x100") if rife and dsn is None else "160x100"
    match = re.fullmatch(r"([0-9]{1,4})[xX×]([0-9]{1,4})", size)
    if match:
        width, height = map(int, match.groups())
        if 1 <= width <= 4096 and 8 <= height <= 4096:
            return width, height
    raise ValueError("expected WIDTHxHEIGHT, with width 1..4096 and height 8..4096")


def main():
    parser = argparse.ArgumentParser(description="Play SQL Doom in a truecolor terminal.")
    parser.add_argument("--dsn", help="PostgreSQL connection string (or use PG* environment variables)")
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--wad", type=Path, help="use a classic WAD (default: bundled shareware)")
    source.add_argument("--game", type=int, help="resume an existing game by ID")
    parser.add_argument("--map", type=str.upper, help="initial map (default: E1M7 in the bundled WAD)")
    parser.add_argument(
        "--skill", type=int, choices=range(1, 6), default=3, help="initial difficulty (default: 3)"
    )
    parser.add_argument("--rife", action="store_true", help="interpolate at up to 5x with local turn preview")
    quality = parser.add_mutually_exclusive_group()
    quality.add_argument("--resolution", metavar="WIDTHxHEIGHT", help="SQL render size (default: 160x100)")
    quality.add_argument(
        "--low-res", dest="resolution", action="store_const", const="64x40", help="render at 64x40"
    )
    quality.add_argument(
        "--detail", dest="resolution", action="store_const", const="160x100",
        help="render at 160x100",
    )
    parser.add_argument("--delta", action="store_true", help="receive changed eight-column strips")
    parser.add_argument(
        "--predict-turn", action="store_true", help="show turns before the next SQL frame arrives"
    )
    parser.add_argument(
        "--rtt-ms",
        metavar="MS",
        help="override the simulated round-trip delay for local play",
    )
    parser.add_argument("--mute", action="store_true", help="silence game audio")
    args = parser.parse_args()
    if args.rife and args.delta:
        parser.error("--rife uses full frames; omit --delta")
    try:
        args.rtt_ms = local_rtt_ms(args.dsn, args.rtt_ms)
    except ValueError as error:
        parser.error(f"invalid local RTT: {error}")
    try:
        args.resolution = render_resolution(args.dsn, args.resolution, args.rife)
    except ValueError as error:
        parser.error(str(error))
    if args.dsn is None:
        args.dsn = os.environ.get("DOOM_LOCAL_DSN", "")
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        parser.error("requires an interactive terminal")

    async def run():
        keys = Keyboard()
        with screen(keys):
            await first(play(args, keys), keys.quit.wait())

    try:
        asyncio.run(run())
    except (OSError, ValueError, psycopg.Error) as error:
        parser.exit(1, f"play: {error}\n")


if __name__ == "__main__":
    main()
