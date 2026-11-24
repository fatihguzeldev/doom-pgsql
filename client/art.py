import re
import struct
from dataclasses import dataclass
from functools import lru_cache


@dataclass(frozen=True)
class Image:
    width: int
    height: int
    rgb: bytes
    alpha: bytes | None = None
    left: int = 0
    top: int = 0


@lru_cache(maxsize=1)
def _palette_colors(palette):
    return tuple(palette[i : i + 3] for i in range(0, len(palette), 3))


def world_image(frame, palette):
    # sql pixels arrive in column-major order
    w, h = frame["width"], frame["height"]
    pixels, shades = frame["pixels"], frame["shades"]
    colors = _palette_colors(palette)
    rgb = b"".join(colors[256 * shades[i] + pixels[i]] for y in range(h) for i in range(y, w * h, h))
    return Image(w, h, rgb)


def _directory(wad):
    lumps, maps = {}, []
    if len(wad) < 12 or wad[:4] not in (b"IWAD", b"PWAD"):
        return lumps, ()
    count, start = struct.unpack_from("<II", wad, 4)
    end = start + 16 * count
    if end > len(wad):
        return lumps, ()
    data = memoryview(wad)
    previous = ""
    for pos, size, raw_name in struct.iter_unpack("<II8s", data[start:end]):
        name = raw_name.partition(b"\0")[0].decode("latin1").upper()
        if name == "THINGS" and re.fullmatch(r"[A-Z0-9_]{1,8}", previous):
            maps.append(previous)
        previous = name
        if pos + size <= len(data):
            lumps[name] = data[pos : pos + size]
    return lumps, tuple(dict.fromkeys(maps))


def _patch(data, palette):
    if len(data) < 8 or len(palette) < 768:
        return None
    w, h, left, top = struct.unpack_from("<HHhh", data)
    header = 8 + 4 * w
    if not 0 < w * h <= 640 * 400 or header > len(data):
        return None
    indices, alpha = bytearray(w * h), bytearray(w * h)
    for x, (pos,) in enumerate(struct.iter_unpack("<I", data[8:header])):
        if pos < header:
            return None
        previous_y = -1
        # cap repeated empty posts when patch columns share offsets
        limit = min(len(data), pos + 8 * h + 5)
        while pos < limit and data[pos] != 255:
            if pos + 4 > limit:
                return None
            y, count = data[pos], data[pos + 1]
            if y <= previous_y:
                y += previous_y
            previous_y = y
            if y + count > h or pos + count + 4 > limit:
                return None
            rows = slice(y * w + x, (y + count) * w + x, w)
            indices[rows] = data[pos + 3 : pos + 3 + count]
            alpha[rows] = b"\xff" * count
            pos += 4 + count
        if pos >= limit:
            return None
    rgb = bytearray(3 * w * h)
    palette = bytes(palette[:768])
    for channel in range(3):
        rgb[channel::3] = indices.translate(palette[channel::3])
    return Image(w, h, bytes(rgb), bytes(alpha) if 0 in alpha else None, left, top)


def _sound_wav(data):
    if len(data) < 8:
        return None
    fmt, rate, size = struct.unpack_from("<HHI", data)
    if fmt != 3 or rate == 0 or not 48 < size <= len(data) - 8:
        return None
    # dmx leaves 16 padding samples at each end of a doom sound lump
    pcm = bytes(data[24 : 8 + size - 16])
    pad = b"\0" * (len(pcm) % 2)
    header = struct.pack("<IHHIIHH", 16, 1, 1, rate, rate, 1, 8)
    riff_size = struct.pack("<I", 36 + len(pcm) + len(pad))
    return b"RIFF" + riff_size + b"WAVEfmt " + header + b"data" + struct.pack("<I", len(pcm)) + pcm + pad


def _opaque_runs(image, x, y, width, height, source_height=200):
    x -= image.left
    y -= image.top
    x0 = max(0, (x * width + 319) // 320)
    x1 = min(width, ((x + image.width) * width + 319) // 320)
    y0 = max(0, (y * height + source_height - 1) // source_height)
    y1 = min(height, ((y + image.height) * height + source_height - 1) // source_height)
    columns = [dx * 320 // width - x for dx in range(x0, x1)]
    for dy in range(y0, y1):
        row = (dy * source_height // height - y) * image.width
        offset = (dy * width + x0) * 3
        run = bytearray()
        for col in columns:
            at = row + col
            if image.alpha is None or image.alpha[at]:
                run.extend(image.rgb[at * 3 : at * 3 + 3])
            elif run:
                yield offset - len(run), bytes(run)
                run.clear()
            offset += 3
        if run:
            yield offset - len(run), bytes(run)


_STATUS_PATCHES = (
    "STBAR", "STARMS", "STTPRCNT",
    *(f"STTNUM{n}" for n in range(10)),
    *(f"STYSNUM{n}" for n in range(10)),
    *(f"STGNUM{n}" for n in range(3, 8)),
    *(f"STKEYS{n}" for n in range(3)),
    *(f"STFST{n}0" for n in range(5)), "STFDEAD0",
)


def _stamp(canvas, image, x, y):
    if image is None:
        return
    for offset, pixels in _opaque_runs(image, x, y, 320, 32, source_height=32):
        canvas[offset : offset + len(pixels)] = pixels


class Art:
    def __init__(self, images, maps, sounds, music):
        self.title = images.get("TITLEPIC")
        self.skull = images.get("M_SKULL1")
        self.maps = maps
        self.sounds = sounds
        self.music = music
        self._images = images
        self._overlay_key = None
        self._runs = ()
        bar = images.get("STBAR")
        self.has_status_bar = (
            bar is not None and (bar.width, bar.height) == (320, 32)
            and all(f"STTNUM{n}" in images for n in range(10))
        )
        if self.has_status_bar:
            canvas = bytearray(bar.rgb)
            _stamp(canvas, images.get("STARMS"), 104, 0)
            for i, slot in enumerate(range(2, 8)):
                prefix = "STYSNUM" if slot == 2 else "STGNUM"
                _stamp(canvas, images.get(f"{prefix}{slot}"), 111 + 12 * (i % 3), 4 + 10 * (i // 3))
            for x in (90, 221):
                _stamp(canvas, images.get("STTPRCNT"), x, 3)
            # the engine has one ammo pool, with a pickup cap of 400 rounds
            for row, maximum in enumerate((400, 0, 0, 0)):
                y = 5 + 6 * row
                self._bar_number(canvas, "STYSNUM", maximum, 314, y)
                if row:
                    self._bar_number(canvas, "STYSNUM", 0, 288, y)
            self._bar_background = bytes(canvas)

    @classmethod
    def from_bytes(cls, wad):
        lumps, maps = _directory(wad)
        palette = lumps.get("PLAYPAL", b"")
        names = [
            "TITLEPIC",
            "PISFA0",
            "M_SKULL1",
            "PISGA0",
            "PISGB0",
            "PISGC0",
        ]
        names.extend(_STATUS_PATCHES)
        images = {}
        for name in names:
            image = _patch(lumps.get(name, b""), palette)
            if image is not None:
                images[name] = image
        sounds = {
            name: wav for name, data in lumps.items()
            if re.fullmatch(r"DS[A-Z0-9_]{1,6}", name) and (wav := _sound_wav(data))
        }
        music = {
            name: data for name, data in lumps.items()
            if re.fullmatch(r"D_[A-Z0-9_]{1,6}", name) and bytes(data[:4]) in (b"MUS\x1a", b"MThd")
        }
        return cls(images, maps, sounds, music)

    def face(self, health):
        tier = (100 - min(100, max(0, health))) * 5 // 101
        return self._images.get("STFDEAD0" if health <= 0 else f"STFST{tier}0")

    def _bar_number(self, canvas, prefix, value, right, y):
        zero = self._images.get(prefix + "0")
        if zero is None:
            return
        for digit in reversed(str(min(999, max(0, value)))):
            right -= zero.width
            _stamp(canvas, self._images.get(prefix + digit), right, y)

    @lru_cache(maxsize=1)
    def status_bar(self, health, armor, ammo, keys):
        if not self.has_status_bar:
            return None
        canvas = bytearray(self._bar_background)
        for value, right in ((ammo, 44), (health, 90), (armor, 221)):
            self._bar_number(canvas, "STTNUM", value, right, 3)
        self._bar_number(canvas, "STYSNUM", ammo, 288, 5)
        _stamp(canvas, self.face(health), 143, 0)
        for slot in range(3):
            if keys & (1 << slot):
                _stamp(canvas, self._images.get(f"STKEYS{slot}"), 239, 3 + 10 * slot)
        return Image(320, 32, bytes(canvas))

    def draw_weapon(self, world, shot_tic=None):
        weapon = self._images.get("PISGA0")
        if weapon is None:
            return world
        flash = None
        if shot_tic is not None and 0 <= shot_tic < 8:
            gun = "PISGC0" if 3 <= shot_tic < 6 else "PISGB0"
            weapon = self._images.get(gun, weapon)
            if shot_tic < 3:
                flash = self._images.get("PISFA0")
        w, h = world.width, world.height
        key = (w, h, weapon, flash)
        if key != self._overlay_key:
            self._runs = list(_opaque_runs(weapon, 0, 32, w, h))
            if flash is not None:
                self._runs.extend(_opaque_runs(flash, 0, 32, w, h))
            self._overlay_key = key
        canvas = bytearray(world.rgb)
        for start, pixels in self._runs:
            canvas[start : start + len(pixels)] = pixels
        return Image(w, h, bytes(canvas))
