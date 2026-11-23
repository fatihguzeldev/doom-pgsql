import re
import shutil
import unicodedata
from functools import lru_cache

BACKGROUND = "\x1b[48;2;18;14;23m"
SGR = re.compile(r"\x1b\[[\d;]*m")


def cell_width(text):
    return sum(
        0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in text
    )


def fit_text(text, width):
    text = "".join(c for c in str(text) if c.isprintable())
    if cell_width(text) <= width:
        return text
    clipped = []
    used = 0
    for c in text:
        extra = cell_width(c)
        if used + extra > width:
            break
        clipped.append(c)
        used += extra
    return "".join(clipped)


def fit_image(w, h, cols, rows):
    if cols < 1 or rows < 1:
        return 0, 0
    width = max(1, min(cols, 2 * rows * w // h))
    height = max(1, min(rows, round(width * h / (2 * w))))
    return width, height


@lru_cache(maxsize=8192)
def ansi_rgb(rgb):
    return f"{rgb[0]};{rgb[1]};{rgb[2]}m"


def image_rows(picture, width, height):
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
                row.append("\x1b[48;2;" + ansi_rgb(bg))
            if top == bottom:
                row.append(" ")
            else:
                if top != fg:
                    fg = top
                    row.append("\x1b[38;2;" + ansi_rgb(fg))
                row.append("▀")
        result.append("".join(row))
    return result


class Page:
    def __init__(self):
        self.width, self.height = shutil.get_terminal_size()
        self.space = max(0, self.width - 2)
        self.rows = [[] for _ in range(self.height)]

    def put(self, x, y, styled):
        if 0 <= x < self.width - 1 and 0 <= y < self.height and styled:
            self.rows[y].append((x, styled))

    def centered(self, y, text, color):
        plain = fit_text(text, self.space)
        self.put((self.width - cell_width(plain)) // 2, y, color + plain)
