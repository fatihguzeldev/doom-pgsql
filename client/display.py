import math
import sys

from .ansi import BACKGROUND, SGR, Page, cell_width, fit_image, fit_text, image_rows
from .art import Image
from .widgets import (
    COPPER,
    EDGE,
    GOLD,
    SELECTED,
    TEXT,
    VIOLET,
    compact_wordmark,
    control_rows,
    draw_logo,
    keycap,
    logo_for,
)


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


class Display:
    def __init__(self, art=None):
        self.art = art
        skull = art.skull if art is not None else None
        self._cursor = image_rows(skull, 6, 3) if skull else ()
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
        page = Page()
        logo = logo_for(page)
        y = page.height // 2
        draw_logo(page, logo, y - len(logo) - 2, phase)
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
            self._rendered = image_rows(image, cols, rows)
            self._render_key = key
        return self._rendered

    def _full_status_bar(self, world, cols, rows):
        # half-block cells provide one pixel across and two pixels down
        return (
            self.art is not None and self.art.has_status_bar
            and min(world.width, cols) >= 320 and min(world.height, 2 * rows) >= 200
        )

    def paint(
        self, world, status, turn=0.0, fps=0.0, shot_age=None, *, sql_fps=None, phase=0, lit_keys=frozenset(),
        automap=None, pose=None,
    ):
        page = Page()
        logo = logo_for(page)
        controls = control_rows(page.space, status.get("auto_walk", False), lit_keys)
        if len(controls) + 4 > page.height:
            controls = [(8, keycap("esc", 3, lit_keys) + TEXT + " menu")] if page.space >= 8 else []
        footer = len(controls) + 1 + int(page.height >= 28)
        above_fps = int(page.height >= 22)
        below_fps = int(page.height >= 18)
        map_ready = automap is not None and pose is not None
        compact = map_ready and page.height <= 25
        header = (1 + int(page.height >= 16)) if compact else len(logo) + above_fps + 1 + below_fps
        reserve = max(header, footer)
        usable = max(1, page.height - (header + footer if map_ready else 2 * reserve))
        has_map = map_ready and usable >= 4 and page.space >= 24
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
        cols, rows = fit_image(world.width, world.height, room_w, room_h)
        if not cols:
            self._present(page)
            return
        if side:
            map_height = min(max(3, map_width // 2), rows - 1)
        below_map = map_height + 1 if map_height and not side else 0
        x = (page.width - cols - (map_width + 2 if side else 0)) // 2
        y = ((page.height - rows) // 2 if not has_map
             else header + (usable - rows - below_map) // 2)
        readout = f"FPS {fps:.1f}"
        if sql_fps is not None:
            readout += f"   SQL {sql_fps:.1f}"
        if compact:
            span = cols + (map_width + 2 if side else 0)
            if span >= len(readout) + 12:
                page.put(x, y - header, compact_wordmark(phase))
            page.put(max(0, x + span - len(readout)), y - header, VIOLET + fit_text(readout, page.space))
        else:
            draw_logo(page, logo, y - header, phase)
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
        page = Page()
        logo = logo_for(page)
        gap = int(page.height >= 14)
        options = [fit_text(s, page.space) for s in items]
        heading = fit_text(title.upper(), page.space)
        if page.space < 8 or page.height < 5:
            page.centered(page.height // 2, options[selected] if options else heading, GOLD)
            self._present(page)
            return
        minimum = 36 if art is not None and page.space >= 70 else 18
        width = min(page.space, max(minimum, cell_width(heading), *(4 + cell_width(s) for s in options)))
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
            iw, ih = fit_image(art.width, art.height, img_space, img_height)
        body_h = max(ih, panel_h) if side_by_side else ih + int(ih > 0) * gap + panel_h
        top = max(0, (page.height - len(logo) - gap - body_h - gap - 1) // 2)
        draw_logo(page, logo, top, phase)
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
                self._title_rows = image_rows(art, iw, ih)
                self._title_key = key
            for i, line in enumerate(self._title_rows):
                page.put(image_x, image_y + i, line)
        page.put(menu_x, menu_y, COPPER + fit_text(heading, width))
        page.put(menu_x, menu_y + 1, EDGE + "─" * width)
        start = max(0, min(selected - choices // 2, len(options) - choices))
        gutter = 7 if cursor else 0
        for i in range(start, start + choices):
            label = fit_text(options[i], max(0, width - gutter - 4))
            y = menu_y + 2 + (i - start) * stride + int(cursor)
            if i == selected:
                prefix = "   " if cursor else " › "
                line = SELECTED + GOLD + prefix + label + " " * max(0, width - gutter - 3 - cell_width(label))
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
        caps = [" ".join(keycap(key, 3, lit_keys) for key in group) for group, _ in groups]
        hint = "   ".join(f"{cap}{TEXT} {label}" for cap, (_, label) in zip(caps, groups))
        if cell_width(SGR.sub("", hint)) > page.space:
            hint = " ".join(caps)
        width = cell_width(SGR.sub("", hint))
        if width <= page.space:
            page.put((page.width - width) // 2, footer_y, hint)
        else:
            page.centered(footer_y, "Enter / Esc", TEXT)
        self._present(page)
