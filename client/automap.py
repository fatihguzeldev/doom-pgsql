import math
from collections import deque

# one braille character holds two columns of four map dots
UNITS_PER_DOT = 24
_DOTS = ((1, 8), (2, 16), (4, 32), (64, 128))
_HEADINGS = "→↗↑↖←↙↓↘"
_STYLES = {"step": 1, "wall": 2, "special": 3, "exit": 4}
_INK = (
    "",
    "\x1b[38;2;138;102;135m",
    "\x1b[38;2;231;144;118m",
    "\x1b[38;2;255;210;128m",
    "\x1b[38;2;104;217;206m",
)
_TRAIL = "\x1b[38;2;147;157;200m"
_PLAYER = "\x1b[38;2;255;248;230m"
EXIT_FLAG = "⚑"
_RESET_FG = "\x1b[39m"


def _line_dots(x0, y0, x1, y1, left, top, right, bottom):
    if (
        max(x0, x1) < left
        or min(x0, x1) > right
        or max(y0, y1) < top
        or min(y0, y1) > bottom
    ):
        return
    steep = abs(y1 - y0) > abs(x1 - x0)
    if steep:
        x0, y0, x1, y1 = y0, x0, y1, x1
        left, top, right, bottom = top, left, bottom, right
    if x0 > x1:
        x0, y0, x1, y1 = x1, y1, x0, y0
    slope = (y1 - y0) / (x1 - x0) if x1 != x0 else 0
    for x in range(max(left, x0), min(right, x1) + 1):
        y = round(y0 + (x - x0) * slope)
        if top <= y <= bottom:
            yield (y, x) if steep else (x, y)


class Automap:
    def __init__(self, lines):
        self._lines = [
            (
                round(x1 / UNITS_PER_DOT),
                -round(y1 / UNITS_PER_DOT),
                round(x2 / UNITS_PER_DOT),
                -round(y2 / UNITS_PER_DOT),
                _STYLES[kind],
            )
            for x1, y1, x2, y2, kind in lines
        ]
        self._view = None
        self._rows = []
        self._trail = deque(maxlen=32)
        self._exits = [
            (round((x0 + x1) / 2), round((y0 + y1) / 2))
            for x0, y0, x1, y1, ink in self._lines if ink == _STYLES["exit"]
        ]

    @classmethod
    async def load(cls, db, level):
        result = await db.execute(
            """SELECT l.a[0] AS x1, l.a[1] AS y1, l.b[0] AS x2, l.b[1] AS y2,
                      CASE WHEN (l.flags & 32)<>0 THEN 'wall'
                           WHEN l.special IN (11,51,52,124) THEN 'exit'
                           WHEN l.special<>0 THEN 'special'
                           WHEN l.back IS NULL OR (l.flags & 1)<>0 THEN 'wall'
                           ELSE 'step' END AS kind
               FROM doom.lines l
               JOIN doom.sides f ON (f.level,f.id)=(l.level,l.front)
               JOIN doom.sectors a ON (a.level,a.id)=(f.level,f.sector)
               LEFT JOIN doom.sides b ON (b.level,b.id)=(l.level,l.back)
               LEFT JOIN doom.sectors z ON (z.level,z.id)=(b.level,b.sector)
               WHERE l.level=%s AND (l.flags & 128)=0 AND
                   (l.back IS NULL OR l.special<>0 OR (l.flags & 33)<>0 OR
                    (a.floor_z,a.ceiling_z) IS DISTINCT FROM (z.floor_z,z.ceiling_z))""",
            (level,),
        )
        return cls(
            (r["x1"], r["y1"], r["x2"], r["y2"], r["kind"])
            for r in await result.fetchall()
        )

    def rows(self, x, y, yaw, width, height):
        if width <= 0 or height <= 0:
            return [""] * max(0, height)
        cx, cy = round(x / UNITS_PER_DOT), -round(y / UNITS_PER_DOT)
        direction = math.floor(yaw / (math.pi / 4) + 0.5) % 8
        view = (cx, cy, direction, width, height)
        if view == self._view:
            return self._rows
        if not self._trail or self._trail[-1] != (cx, cy):
            self._trail.append((cx, cy))

        left, top = cx - width, cy - height * 2
        right, bottom = left + width * 2 - 1, top + height * 4 - 1
        masks = bytearray(width * height)
        inks = bytearray(width * height)
        for x0, y0, x1, y1, ink in self._lines:
            for wx, wy in _line_dots(x0, y0, x1, y1, left, top, right, bottom):
                dx, dy = wx - left, wy - top
                cell = (dy // 4) * width + dx // 2
                masks[cell] |= _DOTS[dy % 4][dx % 2]
                inks[cell] = max(inks[cell], ink)

        def cell_at(wx, wy):
            if left <= wx <= right and top <= wy <= bottom:
                return ((wy - top) // 4) * width + (wx - left) // 2
            return None

        markers = {}
        for wx, wy in self._trail:
            cell = cell_at(wx, wy)
            if cell is not None and not masks[cell]:
                markers[cell] = (_TRAIL, "·")
        for wx, wy in self._exits:
            cell = cell_at(wx, wy)
            if cell is not None:
                markers[cell] = (_INK[_STYLES["exit"]], EXIT_FLAG)
        markers[cell_at(cx, cy)] = (_PLAYER, _HEADINGS[direction])
        rows = []
        for row in range(height):
            parts = []
            current = ""
            for cell in range(row * width, (row + 1) * width):
                if cell in markers:
                    color, glyph = markers[cell]
                else:
                    color = _INK[inks[cell]]
                    glyph = chr(0x2800 + masks[cell]) if masks[cell] else " "
                if color and color != current:
                    parts.append(color)
                    current = color
                parts.append(glyph)
            if current:
                parts.append(_RESET_FG)
            rows.append("".join(parts))
        self._view, self._rows = view, rows
        return rows
