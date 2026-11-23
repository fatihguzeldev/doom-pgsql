import asyncio
import shutil
from time import monotonic

from .database import saved_games
from .widgets import LOGO_HZ

SKILLS = ("I'm too young to die", "Hey, not too rough", "Hurt me plenty", "Ultra-Violence", "Nightmare!")


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


async def pause_menu(session, keys, display, maps):
    paused = not session.ended
    actions = []
    if paused:
        title = "Paused"
        actions.append(("Resume", "resume"))
    elif session.status["finished"]:
        title = "Level complete"
        following = next_map(session.state["map"], maps, session.status["secret_exit"])
        if following:
            actions.append(("Next map", following))
    else:
        title = "You died"
    actions.extend([("Restart map", "restart"), ("Main menu", "menu"), ("Quit", "quit")])
    row = await menu(keys, display, title, [label for label, _ in actions])
    if row is not None:
        return actions[row][1]
    if not session.ended:
        return "resume"
    if paused:
        keys.menu_keys.put_nowait("end")
        return None
    return "menu"
