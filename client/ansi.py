import base64
import re
import shutil
import struct
import unicodedata
import zlib
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


@lru_cache(maxsize=1)
def inline_picture(picture, cols, rows):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    header = struct.pack(">IIBBBBB", picture.width, picture.height, 8, 2, 0, 0, 0)
    stride = 3 * picture.width
    scanlines = b"".join(b"\0" + picture.rgb[i:i + stride] for i in range(0, len(picture.rgb), stride))
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
           + chunk(b"IDAT", zlib.compress(scanlines, 1)) + chunk(b"IEND", b""))
    payload = base64.b64encode(png).decode("ascii")
    return f"\x1b]1337;File=inline=1;width={cols};height={rows};preserveAspectRatio=0:{payload}\a"


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
