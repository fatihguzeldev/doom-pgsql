import math
import re
import shutil
import sys
import unicodedata
from functools import lru_cache

from .art import Image

BACKGROUND = "\x1b[48;2;18;14;23m"
SELECTED = "\x1b[48;2;75;42;61m"
GOLD = "\x1b[38;2;255;209;137m"
COPPER = "\x1b[38;2;229;140;95m"
VIOLET = "\x1b[38;2;183;135;196m"
TEXT = "\x1b[38;2;235;222;213m"
EDGE = "\x1b[38;2;124;89;121m"

LOGO = (
    ("████▄  ▄████▄ ▄████▄ ██▄  ▄██", "     ", "█████▄ ▄█████ ▄█████ ▄████▄ ██    "),
    ("██ ▀██ ██  ██ ██  ██ ███▄▄███", "     ", "██  ██ ██     ██     ██  ██ ██    "),
    ("██  ██ ██  ██ ██  ██ ██▀██▀██", " ▀▀▀ ", "█████▀ ██ ▀██ ▀████▄ ██  ██ ██    "),
    ("██ ▄██ ██  ██ ██  ██ ██    ██", "     ", "██     ██  ██     ██ ██ ▀██ ██    "),
    ("████▀  ▀████▀ ▀████▀ ██    ██", "     ", "██     ▀████▀ █████▀ ▀███▀█ ██████"),
)
SMALL_LOGO = (
    ("█▀▄ █▀█ █▀█ █▄ ▄█", "   ", "█▀█ █▀▀ █▀▀ █▀█ █  "),
    ("█ █ █ █ █ █ █ ▀ █", " ▀ ", "█▀▀ █ █ ▀▀█ █ █ █  "),
    ("▀▀  ▀▀▀ ▀▀▀ ▀   ▀", "   ", "▀   ▀▀▀ ▀▀▀ ▀▀▙ ▀▀▀"),
)
# The abrupt dark band gives the lettering a chrome horizon.
BRONZE = ("#ffdcac", "#efa36f", "#87415a", "#e06f55", "#ffbd75")
STEEL = ("#c8fbff", "#80d7e8", "#47447a", "#6788cf", "#b5b4ff")
GLINT = "\x1b[38;2;255;246;218m"


def _cells(text):
    return sum(
        0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in text
    )


def _fit_text(text, width):
    text = "".join(c for c in str(text) if c.isprintable())
    if _cells(text) <= width:
        return text
    clipped = []
    used = 0
    for c in text:
        extra = _cells(c)
        if used + extra > width:
            break
        clipped.append(c)
        used += extra
    return "".join(clipped)


def _fit_image(w, h, cols, rows):
    if cols < 1 or rows < 1:
        return 0, 0
    width = max(1, min(cols, 2 * rows * w // h))
    height = max(1, min(rows, round(width * h / (2 * w))))
    return width, height


@lru_cache(maxsize=8192)
def _ansi_rgb(rgb):
    return f"{rgb[0]};{rgb[1]};{rgb[2]}m"


def _image_rows(picture, width, height):
    # Each terminal cell displays two samples, one above the other.
    xs = [(2 * x + 1) * picture.width // (2 * width) for x in range(width)]
    rgb, alpha = picture.rgb, picture.alpha
    result = []
    for y in range(height):
        upper = ((4 * y + 1) * picture.height // (4 * height)) * picture.width
        lower = ((4 * y + 3) * picture.height // (4 * height)) * picture.width
        fg = bg = None
        row = []
        for x in xs:
            a, b = 3 * (upper + x), 3 * (lower + x)
            top, bottom = rgb[a : a + 3], rgb[b : b + 3]
            if alpha is not None:
                if not alpha[upper + x]:
                    top = b"\x12\x0e\x17"
                if not alpha[lower + x]:
                    bottom = b"\x12\x0e\x17"
            if bottom != bg:
                bg = bottom
                row.append("\x1b[48;2;" + _ansi_rgb(bg))
            if top == bottom:
                row.append(" ")
            else:
                if top != fg:
                    fg = top
                    row.append("\x1b[38;2;" + _ansi_rgb(fg))
                row.append("▀")
        result.append("".join(row))
    return result


def _reproject(image, turn):
    if not turn:
        return image
    w, h = image.width, image.height
    cos, sin = math.cos(turn), math.sin(turn)
    rgb = image.rgb
    warped = bytearray(w * h * 3)
    for x in range(w):
        ray = 2 * (x + 0.5) / w - 1
        depth = cos + ray * sin
        if depth <= 0:
            continue
        u = math.floor(w * (1 + (ray * cos - sin) / depth) / 2)
        if 0 <= u < w:
            for y in range(h):
                v = math.floor(h / 2 + (y + 0.5 - h / 2) / depth)
                if 0 <= v < h:
                    src, dst = 3 * (v * w + u), 3 * (y * w + x)
                    warped[dst : dst + 3] = rgb[src : src + 3]
    return Image(w, h, bytes(warped))


class _Page:
    def __init__(self):
        self.width, self.height = shutil.get_terminal_size()
        self.space = max(0, self.width - 2)
        self.rows = [[] for _ in range(self.height)]

    def put(self, x, y, styled):
        if 0 <= x < self.width - 1 and 0 <= y < self.height and styled:
            self.rows[y].append((x, styled))

    def centered(self, y, text, color):
        plain = _fit_text(text, self.space)
        self.put((self.width - _cells(plain)) // 2, y, color + plain)


def _logo(page):
    if page.height >= 28 and page.space >= sum(map(len, LOGO[0])):
        return LOGO
    if page.height >= 18 and page.space >= sum(map(len, SMALL_LOGO[0])):
        return SMALL_LOGO
    return (("DOOM", "-", "PGSQL"),) if page.height >= 8 else ()


def _chrome(text, color, glint):
    ink = "\x1b[38;2;" + _ansi_rgb(bytes.fromhex(color[1:]))
    if glint < -2 or glint >= len(text):
        return ink + text
    left, right = max(0, glint), min(len(text), glint + 3)
    return ink + text[:left] + GLINT + text[left:right] + ink + text[right:]


def _draw_logo(page, logo, y, phase):
    if not logo:
        return
    width = sum(map(len, logo[0]))
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
    # Half-block samples form a pair of mirrored copper sine waves.
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
SGR = re.compile(r"\x1b\[[\d;]*m")


def _keycap(key, size, lit_keys):
    label = KEY_NAMES.get(key, key.upper()).center(size)
    if key in lit_keys:
        face = KEY_AMBER if key in {" ", "e", "r"} else KEY_CYAN
        return face + KEY_INK + label + "\x1b[22m" + BACKGROUND
    return KEY_FACE + label + BACKGROUND


def _control_rows(width, auto_walk, lit_keys):
    compact = width < 71
    size = 5 if width >= 93 else 3 if width >= 58 else 1
    gap = " " if compact else "   "

    def cap(key, span=size):
        return _keycap(key, span, lit_keys)

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
        lengths = [_cells(SGR.sub("", line)) for line in group]
        span = max(lengths)
        total += span
        for row, line, length in zip(rows, group, lengths):
            left = (span - length) // 2
            row.append(" " * left + line + " " * (span - length - left))
    total += len(gap) * (len(groups) - 1)
    return [(total, gap.join(row)) for row in rows if any(SGR.sub("", part).strip() for part in row)]


class Display:
    def __init__(self, art=None):
        self.art = art
        skull = art.skull if art is not None else None
        self._cursor = _image_rows(skull, 6, 3) if skull else ()
        self._previous = None
        self._size = None
        self._world = None
        self._render_key = self._title_key = None
        self._rendered = self._title_rows = ()

    def _present(self, page):
        size = (page.width, page.height)
        output = []
        if self._size != size:
            output.append(BACKGROUND + "\x1b[2J")
            self._previous = [[] for _ in page.rows]
            self._size = size
        for y, (before, after) in enumerate(zip(self._previous, page.rows), 1):
            if before == after:
                continue
            if before:
                output.append(f"\x1b[{y};1H" + BACKGROUND + "\x1b[2K")
            for x, text in after:
                output.extend((f"\x1b[{y};{x + 1}H", BACKGROUND, text))
        self._previous = page.rows
        if output:
            sys.stdout.write("".join(output) + "\x1b[0m")
            sys.stdout.flush()

    def loading(self, target, seconds, phase):
        page = _Page()
        logo = _logo(page)
        y = page.height // 2
        _draw_logo(page, logo, y - len(logo) - 2, phase)
        page.centered(y, f"Loading {target}", GOLD)
        page.centered(y + 2, f"{seconds}s    Q quit", VIOLET)
        self._present(page)

    def _game_rows(self, world, status, turn, shot_age, cols, rows):
        if world is not self._world:
            self._world = world
            self._render_key = None
        health, armor, ammo = (status.get(key, 0) for key in ("health", "armor", "ammo"))
        shot_tic = int(35 * shot_age) if shot_age is not None else None
        keys = status.get("keys", 0)
        key = (turn, health, armor, ammo, keys, shot_tic, cols, rows)
        if self._render_key != key:
            image = _reproject(self._world, turn)
            if self.art is not None:
                image = self.art.compose(
                    image, health=health, armor=armor, ammo=ammo, keys=keys, shot_age=shot_tic,
                    status_bar=self._full_status_bar(world, cols, rows),
                )
            self._rendered = _image_rows(image, cols, rows)
            self._render_key = key
        return self._rendered

    def _full_status_bar(self, world, cols, rows):
        # Half-block cells provide one pixel across and two pixels down.
        return (self.art is not None and self.art.has_status_bar
                and min(world.width, cols) >= 320 and min(world.height, 2 * rows) >= 200)

    def paint(
        self, world, status, turn=0.0, fps=0.0, shot_age=None, *, sql_fps=None, phase=0, lit_keys=frozenset(),
        automap=None, pose=None,
    ):
        page = _Page()
        logo = _logo(page)
        controls = _control_rows(page.space, status.get("auto_walk", False), lit_keys)
        if len(controls) + 4 > page.height:
            controls = [(8, _keycap("esc", 3, lit_keys) + TEXT + " menu")] if page.space >= 8 else []
        footer = len(controls) + 1 + int(page.height >= 28)
        above_fps = int(page.height >= 22)
        below_fps = int(page.height >= 18)
        header = len(logo) + above_fps + 1 + below_fps
        reserve = max(header, footer)
        if automap is None or pose is None:
            usable = max(1, page.height - 2 * reserve)
        else:
            usable = max(1, page.height - header - footer)
        has_map = automap is not None and pose is not None and usable >= 4 and page.space >= 24
        side = has_map and (page.space >= 54 or (usable < 10 and page.space >= 35))
        map_width = map_height = 0
        room_w, room_h = page.space, usable
        if side:
            map_width = min(32, max(12, page.space // 4))
            room_w -= map_width + 2
        elif has_map and usable >= 9:
            map_width = min(page.space, 32)
            map_height = min(7, usable // 3)
            room_h -= map_height + 1
        cols, rows = _fit_image(world.width, world.height, room_w, room_h)
        if not cols:
            self._present(page)
            return
        if side:
            map_height = min(max(3, map_width // 2), rows - 1)
        below_map = map_height + 1 if map_height and not side else 0
        x = (page.width - cols - (map_width + 2 if side else 0)) // 2
        y = ((page.height - rows) // 2 if not has_map
             else header + (usable - rows - below_map) // 2)
        _draw_logo(page, logo, y - header, phase)
        readout = f"FPS {fps:.1f}"
        if sql_fps is not None:
            readout += f"   SQL {sql_fps:.1f}"
        fps_y = y - below_fps - 1
        if len(readout) <= cols:
            page.put(x + cols - len(readout), fps_y, VIOLET + readout)
        else:
            page.centered(fps_y, readout, VIOLET)
        for i, row in enumerate(self._game_rows(world, status, turn, shot_age, cols, rows)):
            page.put(x, y + i, row)
        below = y + rows
        if map_height > 0:
            mx = x + cols + 2 if side else (page.width - map_width) // 2
            my = y + (rows - map_height - 1) // 2 if side else below + 1
            title = "AUTOMAP" + " " * (map_width - 10) + "N ↑"
            page.put(mx, my, VIOLET + title)
            for i, row in enumerate(automap.rows(*pose, map_width, map_height), 1):
                page.put(mx, my + i, row)
        hud = f"HP {status.get('health', 0)}%   ARM {status.get('armor', 0)}%   AMMO {status.get('ammo', 0)}"
        keys = [
            label for bit, label in ((1, "Blue"), (2, "Yellow"), (4, "Red")) if status.get("keys", 0) & bit
        ]
        if keys:
            hud += "   KEYS " + "/".join(keys)
        if not self._full_status_bar(world, cols, rows):
            page.centered(below, hud, GOLD)
        below += 1 + below_map
        if page.height >= 28:
            below += 1
        for i, (used, line) in enumerate(controls):
            page.put((page.width - used) // 2, below + i, line)
        self._present(page)

    def menu(self, title, items, selected=0, *, art=None, phase=0, adjustable=False, lit_keys=frozenset()):
        page = _Page()
        logo = _logo(page)
        gap = int(page.height >= 14)
        options = [_fit_text(s, page.space) for s in items]
        heading = _fit_text(title.upper(), page.space)
        if page.space < 8 or page.height < 5:
            page.centered(page.height // 2, options[selected] if options else heading, GOLD)
            self._present(page)
            return
        minimum = 36 if art is not None and page.space >= 70 else 18
        width = min(page.space, max(minimum, _cells(heading), *(4 + _cells(s) for s in options)))
        available = max(1, page.height - len(logo) - 2 - 2 * gap)
        cursor = bool(
            self._cursor
            and len(options) * 3 + 2 <= available
            and page.space >= width + 7
            and (art is None or page.space >= width + 38 or available >= len(options) * 3 + 10)
        )
        if cursor:
            width += 7
        stride = 3 if cursor else 1
        side_by_side = art is not None and page.space >= width + 31 and page.height >= 13
        choices = min(len(options), max(1, available - 2))
        panel_h = choices * stride + 2
        ih = iw = 0
        if art is not None:
            img_space = min(88, page.space - width - 4) if side_by_side else page.space
            img_height = available if side_by_side else available - panel_h - gap
            iw, ih = _fit_image(art.width, art.height, img_space, img_height)
        body_h = max(ih, panel_h) if side_by_side else ih + int(ih > 0) * gap + panel_h
        top = max(0, (page.height - len(logo) - gap - body_h - gap - 1) // 2)
        _draw_logo(page, logo, top, phase)
        body_y = top + len(logo) + gap
        if side_by_side:
            image_x = (page.width - iw - 4 - width) // 2
            image_y = body_y + (body_h - ih) // 2
            menu_x, menu_y = image_x + iw + 4, body_y + (body_h - panel_h) // 2
        else:
            image_x, image_y = (page.width - iw) // 2, body_y
            menu_x, menu_y = (page.width - width) // 2, body_y + ih + int(ih > 0) * gap
        if iw and ih:
            key = art, iw, ih
            if self._title_key != key:
                self._title_rows = _image_rows(art, iw, ih)
                self._title_key = key
            for i, line in enumerate(self._title_rows):
                page.put(image_x, image_y + i, line)
        page.put(menu_x, menu_y, COPPER + _fit_text(heading, width))
        page.put(menu_x, menu_y + 1, EDGE + "─" * width)
        start = max(0, min(selected - choices // 2, len(options) - choices))
        gutter = 7 if cursor else 0
        for i in range(start, start + choices):
            label = _fit_text(options[i], max(0, width - gutter - 4))
            y = menu_y + 2 + (i - start) * stride + int(cursor)
            if i == selected:
                prefix = "   " if cursor else " › "
                line = SELECTED + GOLD + prefix + label + " " * max(0, width - gutter - 3 - _cells(label))
                if cursor:
                    for j, pixels in enumerate(self._cursor):
                        page.put(menu_x, y + j - 1, pixels)
            else:
                line = TEXT + "   " + label
            page.put(menu_x + gutter, y, line)
        footer_y = min(page.height - 1, body_y + body_h + gap)
        groups = [(("up", "down"), "select")]
        if adjustable:
            groups.append((("left", "right"), "change"))
        groups.extend([(("enter",), "confirm"), (("esc",), "quit" if adjustable else "back")])
        caps = [" ".join(_keycap(key, 3, lit_keys) for key in group) for group, _ in groups]
        hint = "   ".join(f"{cap}{TEXT} {label}" for cap, (_, label) in zip(caps, groups))
        if _cells(SGR.sub("", hint)) > page.space:
            hint = " ".join(caps)
        width = _cells(SGR.sub("", hint))
        if width <= page.space:
            page.put((page.width - width) // 2, footer_y, hint)
        else:
            page.centered(footer_y, "Enter / Esc", TEXT)
        self._present(page)
