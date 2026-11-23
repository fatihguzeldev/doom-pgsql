import argparse
import asyncio
import math
import os
import shutil
import sys
from pathlib import Path
from time import monotonic

import psycopg

if not __package__:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from examples.terminal.art import Art
from examples.terminal.database import open_game, saved_games
from examples.terminal.display import Display
from examples.terminal.keyboard import Keyboard, screen
from examples.terminal.session import Session
from examples.terminal.sound import pistol_sound

BUNDLED_WAD = Path(__file__).resolve().parents[2] / "assets" / "doom1.wad"
SKILLS = ("I'm too young to die", "Hey, not too rough", "Hurt me plenty", "Ultra-Violence", "Nightmare!")
LOGO_HZ = 10


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


async def menu(keys, display, title, items, *, picture=None, adjust=None):
    keys.set_menu(True)
    selected = 0
    last = None
    while not keys.quit.is_set():
        rows = items() if callable(items) else items
        now = monotonic()
        phase = int(now * LOGO_HZ)
        lit = keys.lit_keys(now)
        layout = (shutil.get_terminal_size(), tuple(rows), selected, phase, lit)
        if layout != last:
            display.menu(
                title, rows, selected, art=picture, phase=phase, adjustable=adjust is not None, lit_keys=lit
            )
            last = layout
        try:
            key = await asyncio.wait_for(keys.menu_keys.get(), 1 / 35 if lit else 1 / LOGO_HZ)
        except TimeoutError:
            continue
        if key in ("q", "esc", "end"):
            return None
        if key in ("up", "down"):
            selected = (selected + (1 if key == "down" else -1)) % len(rows)
        elif adjust and key in ("left", "right", "enter") and adjust(selected, -1 if key == "left" else 1):
            continue
        elif key == "enter":
            return selected
    return None


async def new_game_menu(args, maps, display, keys):
    def items():
        return [
            "New game",
            f"Map      < {args.map} >",
            f"Skill    < {SKILLS[args.skill - 1]} >",
            "Load game",
            "Quit",
        ]

    def adjust(row, step):
        if row == 1 and maps:
            args.map = maps[(maps.index(args.map) + step) % len(maps)]
        elif row == 2:
            args.skill = (args.skill - 1 + step) % len(SKILLS) + 1
        else:
            return False
        return True

    while not keys.quit.is_set():
        row = await menu(
            keys,
            display,
            "Main menu",
            items,
            picture=display.art.title,
            adjust=adjust,
        )
        if row != 3:
            return row == 0
        saves = await saved_games(args.dsn)
        labels = [f"#{g['id']}   {g['map']}   Skill {g['difficulty']}   {g['tic'] // 35}s" for g in saves]
        selected = await menu(keys, display, "Load game" if saves else "No saved games", [*labels, "Back"])
        if selected is not None and selected < len(saves):
            args.game = saves[selected]["id"]
            return True
    return False


def next_map(current, maps, secret):
    if len(current) == 4 and current[0] == "E" and current[2] == "M" and current[3].isdigit():
        episode = current[:3]
        if secret:
            candidate = episode + "9"
        elif current[3] == "8":
            return None
        elif current[3] == "9" and current[1] in "1234":
            candidate = episode + {"1": "4", "2": "6", "3": "7", "4": "3"}[current[1]]
        else:
            candidate = episode + str(int(current[3]) + 1)
        return candidate if candidate in maps else None
    if len(current) == 5 and current.startswith("MAP") and current[3:].isdigit():
        number = int(current[3:])
        if number == 30:
            return None
        if secret and number in (15, 31):
            following = 31 if number == 15 else 32
        else:
            following = 16 if number in (31, 32) else number + 1
        candidate = f"MAP{following:02}"
        return candidate if candidate in maps else None
    if current in maps and maps.index(current) + 1 < len(maps):
        return maps[maps.index(current) + 1]
    return None


async def loading_screen(display, target, started):
    while True:
        now = monotonic()
        display.loading(target, int(now - started), int(now * LOGO_HZ))
        await asyncio.sleep(1 / LOGO_HZ)


async def play_session(session, display, keys, maps, started):
    period = 1 / 60 if session.presenter is not None else 1 / 35
    while True:
        now = monotonic()
        world, turn, fps, sql_fps = session.sample_view(now)
        if world is not None and session.status:
            age = now - session.last_shot if session.last_shot is not None else None
            if age is not None and age >= 8 / 35:
                age = None
            display.paint(
                world,
                dict(session.status, auto_walk=keys.auto_walk),
                turn,
                fps,
                sql_fps=sql_fps,
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
        if session.ended:
            finished = session.status["finished"]
            following = (
                next_map(session.state["map"], maps, session.status["secret_exit"]) if finished else None
            )
            actions = [("Next map", following)] if following else []
            actions += [("Restart map", "restart"), ("Main menu", "menu"), ("Quit", "quit")]
            title = "Level complete" if finished else "You died"
        else:
            title = "Paused"
            actions = [
                ("Resume", "resume"),
                ("Restart map", "restart"),
                ("Main menu", "menu"),
                ("Quit", "quit"),
            ]
        row = await menu(keys, display, title, [label for label, _ in actions])
        if row is None:
            if session.ended:
                if title == "Paused":
                    keys.menu_keys.put_nowait("end")
                    continue
                return "menu"
            action = "resume"
        else:
            action = actions[row][1]
        if action != "resume":
            return action
        keys.set_menu(False)
        session.resume()


async def play(args, keys):
    path = args.wad or BUNDLED_WAD
    wad = path.read_bytes() if path.exists() or args.game is None else b""
    art = Art.from_bytes(wad)
    display = Display(art)
    engine = None
    if args.rife:
        from examples.terminal.rife import Rife

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
    with pistol_sound(art.pistol_sound, args.mute) as sound:
        while not keys.quit.is_set():
            if show_menu and not await new_game_menu(args, maps, display, keys):
                return
            started = monotonic()
            target = args.map if args.game is None else f"game #{args.game}"
            state = await first(
                loading_screen(display, target, started),
                open_game(args, wad, level, previous_game),
            )
            args.map, args.skill = state["map"], state["difficulty"]
            if args.map not in maps:
                maps = (*maps, args.map)
            keys.set_menu(False)
            session = Session(args, state, keys, engine)
            tasks = [
                play_session(session, display, keys, maps, started),
                session.capture(),
                session.submit(),
                session.receive(sound),
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
    parser.add_argument("--detail", action="store_true", help="use the native 160x100 SQL renderer with --rife")
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
    if args.detail and not args.rife:
        parser.error("--detail requires --rife")
    if args.rife and args.delta:
        parser.error("--rife uses full frames; omit --delta")
    try:
        args.rtt_ms = local_rtt_ms(args.dsn, args.rtt_ms)
    except ValueError as error:
        parser.error(f"invalid local RTT: {error}")
    args.dsn = args.dsn or ""
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
