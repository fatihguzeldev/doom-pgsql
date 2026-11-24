import math
from pathlib import Path

from .ansi import BACKGROUND, SGR, ansi_rgb, cell_width

LOGO_HZ = 10
SELECTED = "\x1b[48;2;75;42;61m"
GOLD = "\x1b[38;2;255;209;137m"
COPPER = "\x1b[38;2;229;140;95m"
VIOLET = "\x1b[38;2;183;135;196m"
TEXT = "\x1b[38;2;235;222;213m"
EDGE = "\x1b[38;2;124;89;121m"

LOGO = tuple(
    tuple(row.split("|")) for row in Path(__file__).with_name("wordmark.txt").read_text(encoding="utf-8").splitlines()
)
SMALL_LOGO = (
    ("█▀▄ █▀█ █▀█ █▄ ▄█", "   ", "█▀█ █▀▀ █▀▀ █▀█ █  "),
    ("█ █ █ █ █ █ █ ▀ █", " ▀ ", "█▀▀ █ █ ▀▀█ █ █ █  "),
    ("▀▀  ▀▀▀ ▀▀▀ ▀   ▀", "   ", "▀   ▀▀▀ ▀▀▀ ▀▀▙ ▀▀▀"),
)
BRONZE = ("#ffdcac", "#efa36f", "#87415a", "#e06f55", "#ffbd75")
STEEL = ("#c8fbff", "#80d7e8", "#47447a", "#6788cf", "#b5b4ff")
GLINT = "\x1b[38;2;255;246;218m"


def logo_for(page):
    if page.height >= 28 and page.space >= max(sum(map(len, row)) for row in LOGO):
        return LOGO
    if page.height >= 18 and page.space >= sum(map(len, SMALL_LOGO[0])):
        return SMALL_LOGO
    return (("DOOM", "-", "PGSQL"),) if page.height >= 8 else ()


def _chrome(text, color, glint):
    ink = "\x1b[38;2;" + ansi_rgb(bytes.fromhex(color[1:]))
    if glint < -2 or glint >= len(text):
        return ink + text
    left, right = max(0, glint), min(len(text), glint + 3)
    return ink + text[:left] + GLINT + text[left:right] + ink + text[right:]


def compact_wordmark(phase):
    return _chrome("DOOM-PGSQL", BRONZE[0], phase % 30 - 4)


def draw_logo(page, logo, y, phase):
    if not logo:
        return
    width = max(sum(map(len, row)) for row in logo)
    if width > page.space:
        page.centered(y, "DOOM-PGSQL", GOLD)
        return
    travel = min(2, (page.space - width) // 2)
    x = (page.width - width) // 2 + round(travel * math.sin(phase * math.tau / 40))
    for i, (left, dash, right) in enumerate(logo):
        shade = round(i * 4 / max(1, len(logo) - 1))
        glint = (phase * 2) % (width + 36) - i - 4
        lettering = _chrome(left, BRONZE[shade], glint) + EDGE + dash
        lettering += _chrome(right, STEEL[shade], glint - len(left + dash))
        page.put(x, y + i, lettering)
    if logo is not LOGO:
        return
    wing = min(22, (page.space - width) // 2 - 2 - travel)
    if wing < 6:
        return
    wave = [[" "] * wing for _ in logo]
    for column in range(wing):
        angle = column * 0.31 + phase * math.tau / 32
        sample = round((1 + math.sin(angle)) * (2 * len(logo) - 1) / 2)
        wave[sample // 2][column] = "▄" if sample % 2 else "▀"
    for row, pixels in enumerate(wave):
        line = "".join(pixels)
        page.put(x - wing - 2, y + row, COPPER + line)
        page.put(x + width + 2, y + row, VIOLET + line[::-1])


KEY_FACE = "\x1b[48;2;59;45;66m" + TEXT
KEY_CYAN = "\x1b[48;2;99;237;229m"
KEY_AMBER = "\x1b[48;2;255;191;112m"
KEY_INK = "\x1b[1;38;2;29;22;33m"
KEY_NAMES = {"up": "↑", "down": "↓", "left": "←", "right": "→", " ": "SPACE", "esc": "Esc", "enter": "Enter"}


def keycap(key, size, lit_keys):
    label = KEY_NAMES.get(key, key.upper()).center(size)
    if key in lit_keys:
        face = KEY_AMBER if key in {" ", "e", "r"} else KEY_CYAN
        return face + KEY_INK + label + "\x1b[22m" + BACKGROUND
    return KEY_FACE + label + BACKGROUND


def control_rows(width, auto_walk, lit_keys):
    compact = width < 71
    size = 5 if width >= 93 else 3 if width >= 58 else 1
    gap = " " if compact else "   "

    def cap(key, span=size):
        return keycap(key, span, lit_keys)

    def cluster(top, bottom, caption):
        return (cap(top), " ".join(cap(key) for key in bottom), VIOLET + caption)

    actions = cap("e") + TEXT + " use  " + cap("r") + TEXT + (" auto" if compact else " auto-walk")
    fire = cap(" ", 9 if compact else 13) + TEXT + " fire"
    toggle = GOLD + "● AUTO-WALK" if auto_walk else ""
    system = (cap("esc", max(3, size)) + TEXT + " menu", cap("q", max(3, size)) + TEXT + " quit", "")
    groups = [
        cluster("w", "asd", "MOVE"),
        cluster("up", ("left", "down", "right"), "MOVE/TURN" if width >= 58 else "ARROWS"),
        ("", cap("j") + " " + cap("l"), VIOLET + "TURN"),
        (actions, fire, toggle),
        system,
    ]
    if width < 44:
        groups = [
            cluster("w", "asd", ""),
            cluster("up", ("left", "down", "right"), ""),
            ("", cap("j") + " " + cap("l"), ""),
            (cap("e") + " " + cap("r"), cap(" ", 7), GOLD + "AUTO ●" if auto_walk else VIOLET + "AUTO ○"),
            (cap("esc", 3), cap("q", 3), ""),
        ]
    if width < 29:
        line = cap("esc", 3) + TEXT + " menu"
        return [(8, line)] if width >= 8 else []

    rows = [[], [], []]
    total = 0
    for group in groups:
        lengths = [cell_width(SGR.sub("", line)) for line in group]
        span = max(lengths)
        total += span
        for row, line, length in zip(rows, group, lengths):
            left = (span - length) // 2
            row.append(" " * left + line + " " * (span - length - left))
    total += len(gap) * (len(groups) - 1)
    return [(total, gap.join(row)) for row in rows if any(SGR.sub("", part).strip() for part in row)]
