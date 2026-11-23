import math
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
    r"    ____   ____   ____   __  ___",
    r"   / __ \ / __ \ / __ \ /  |/  /",
    r"  / /_/ // /_/ // /_/ // /|_/ / ",
    r" /_____/ \____/ \____//_/  /_/  ",
)
SMALL_LOGO = (
    r"  ___    ___   ___   __  __ ",
    r" |   \  / _ \ / _ \ |  \/  |",
    r" |___/  \___/ \___/ |_|  |_|",
)
WING = ("          ____", "   __..--'// /", "--===/////__/ ", "      /___/   ")
MIRROR = str.maketrans("/\\", "\\/")
CONTROLS = (
    ("WASD", "move"),
    ("J/L", "turn"),
    ("Space", "fire"),
    ("E", "use"),
    ("R", "auto-walk"),
    ("Esc", "menu"),
    ("Q", "quit"),
)


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
    if page.height >= 28 and page.space >= 36:
        return LOGO
    if page.height >= 18 and page.space >= 30:
        return SMALL_LOGO
    if page.height >= 10:
        return ("D O O M",)
    return ()


def _draw_logo(page, logo, y):
    colors = (GOLD, COPPER, VIOLET, EDGE) if len(logo) == 4 else (GOLD, COPPER, VIOLET)
    for i, line in enumerate(logo):
        if logo == LOGO and page.space >= 74:
            wing = WING[i]
            right = wing[::-1].translate(MIRROR)
            x = (page.width - len(line) - 2 * len(wing) - 4) // 2
            page.put(x, y + i, EDGE + wing + "  " + colors[i] + line + "  " + EDGE + right)
        else:
            page.centered(y + i, line, colors[i])


def _control_rows(width, auto_walk):
    rows, parts, used = [], [], 0
    gap = " " if width < 55 else "   "
    for key, label in CONTROLS:
        if width < 55 and key == "Space":
            key = "Spc"
        if width < 55 and key == "R":
            label = "auto"
        if key == "R" and auto_walk:
            label += " ON"
        size = len(key) + len(label) + 1
        if parts and used + len(gap) + size > width:
            rows.append((used, "".join(parts)))
            parts, used = [], 0
        if parts:
            parts.append(gap)
            used += len(gap)
        if size <= width:
            parts.append(COPPER + key + TEXT + " " + label)
            used += size
    if parts:
        rows.append((used, "".join(parts)))
    return rows


class Display:
    def __init__(self, art=None):
        self.art = art
        skull = art.skull if art is not None else None
        self._cursor = _image_rows(skull, 6, 3) if skull else ()
        self._previous = None
        self._size = None
        self._frame = self._palette = self._world = None
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

    def _game_rows(self, frame, palette, status, turn, shot_age, cols, rows):
        if palette is not self._palette:
            self._palette = palette
            self._colors = [bytes(palette[i : i + 3]) for i in range(0, len(palette), 3)]
            self._frame = None
        if frame is not self._frame:
            self._frame = frame
            w, h = frame["width"], frame["height"]
            pixels, shades = frame["pixels"], frame["shades"]
            rgb = b"".join(
                self._colors[256 * shades[i] + pixels[i]] for y in range(h) for i in range(y, w * h, h)
            )
            self._world = Image(w, h, rgb)
            self._render_key = None
        health, armor, ammo = (status.get(key, 0) for key in ("health", "armor", "ammo"))
        shot_tic = int(35 * shot_age) if shot_age is not None else None
        keys = status.get("keys", 0)
        key = (turn, health, armor, ammo, keys, shot_tic, cols, rows)
        if self._render_key != key:
            image = _reproject(self._world, turn)
            if self.art is not None:
                image = self.art.compose(
                    image, health=health, armor=armor, ammo=ammo, keys=keys, shot_age=shot_tic
                )
            self._rendered = _image_rows(image, cols, rows)
            self._render_key = key
        return self._rendered

    def paint(self, frame, palette, status, turn=0.0, fps=0.0, shot_age=None):
        page = _Page()
        logo = _logo(page)
        controls = _control_rows(page.space, status.get("auto_walk", False))
        if len(controls) + 4 > page.height:
            controls = [(len("Esc menu"), COPPER + "Esc" + TEXT + " menu")] if page.space >= 8 else []
        footer = len(controls) + 1 + int(page.height >= 28)
        reserve = max(len(logo) + 1, footer)
        cols, rows = _fit_image(
            frame["width"], frame["height"], page.space, max(1, page.height - 2 * reserve)
        )
        if not cols:
            self._present(page)
            return
        x = (page.width - cols) // 2
        y = (page.height - rows) // 2
        _draw_logo(page, logo, y - len(logo) - 1)
        readout = f"SQL FPS {fps:.1f}"
        game = status.get("game")
        identity = str(status.get("map") or "")
        if game is not None:
            identity = f"{identity}  /  GAME {game}" if identity else f"GAME {game}"
        left = _fit_text(identity, max(0, cols - len(readout) - 2))
        if left:
            page.put(x, y - 1, GOLD + left)
        if len(readout) <= cols:
            page.put(x + cols - len(readout), y - 1, VIOLET + readout)
        else:
            page.centered(y - 1, readout, VIOLET)
        for i, row in enumerate(self._game_rows(frame, palette, status, turn, shot_age, cols, rows)):
            page.put(x, y + i, row)
        below = y + rows
        hud = f"HP {status.get('health', 0)}%   ARM {status.get('armor', 0)}%   AMMO {status.get('ammo', 0)}"
        keys = [
            label for bit, label in ((1, "Blue"), (2, "Yellow"), (4, "Red")) if status.get("keys", 0) & bit
        ]
        if keys:
            hud += "   KEYS " + "/".join(keys)
        page.centered(below, hud, GOLD)
        below += 1
        if page.height >= 28:
            below += 1
        for i, (used, line) in enumerate(controls):
            page.put((page.width - used) // 2, below + i, line)
        self._present(page)

    def menu(self, title, items, selected=0, *, art=None, hint="↑↓ Select   Enter Confirm   Esc Back"):
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
        _draw_logo(page, logo, top)
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
        page.centered(min(page.height - 1, body_y + body_h + gap), hint, VIOLET)
        self._present(page)
