"""Classic Doom graphics and pistol sound for the terminal client."""

import re
import struct
from dataclasses import dataclass


@dataclass(frozen=True)
class Image:
    width: int
    height: int
    rgb: bytes
    alpha: bytes | None = None
    left: int = 0
    top: int = 0


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
        # Offsets can share a column. Bound scans of repeated empty posts in malformed patches.
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


def _pistol_wav(data):
    if len(data) < 8:
        return None
    fmt, rate, size = struct.unpack_from("<HHI", data)
    if fmt != 3 or rate == 0 or not 48 < size <= len(data) - 8:
        return None
    # DMX leaves 16 padding samples at each end of a Doom sound lump.
    pcm = bytes(data[24 : 8 + size - 16])
    pad = b"\0" * (len(pcm) % 2)
    header = struct.pack("<IHHIIHH", 16, 1, 1, rate, rate, 1, 8)
    riff_size = struct.pack("<I", 36 + len(pcm) + len(pad))
    return b"RIFF" + riff_size + b"WAVEfmt " + header + b"data" + struct.pack("<I", len(pcm)) + pcm + pad


def _opaque_runs(image, x, y, width, height, bottom):
    """Sample a patch placed in Doom's 320 by 200 coordinate space."""
    x -= image.left
    y -= image.top
    x0 = max(0, (x * width + 319) // 320)
    x1 = min(width, ((x + image.width) * width + 319) // 320)
    y0 = max(0, (y * height + 199) // 200)
    y1 = min(bottom, ((y + image.height) * height + 199) // 200)
    columns = [dx * 320 // width - x for dx in range(x0, x1)]
    for dy in range(y0, y1):
        row = (dy * 200 // height - y) * image.width
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


class Art:
    def __init__(self, images, maps, pistol_sound):
        self.title = images.get("TITLEPIC")
        self.skull = images.get("M_SKULL1")
        self.maps = maps
        self.pistol_sound = pistol_sound
        self._images = images
        bar = images.get("STBAR")
        self.has_status_bar = (
            bar is not None
            and (bar.width, bar.height) == (320, 32)
            and all(f"STTNUM{i}" in images for i in range(10))
        )
        self._overlay_key = None
        self._runs = ()

    @classmethod
    def from_bytes(cls, wad):
        lumps, maps = _directory(wad)
        palette = lumps.get("PLAYPAL", b"")
        names = [
            "TITLEPIC",
            "STBAR",
            "STTPRCNT",
            "STARMS",
            "STFDEAD0",
            "PISFA0",
            "M_SKULL1",
            "PISGA0",
            "PISGB0",
            "PISGC0",
            "STKEYS0",
            "STKEYS1",
            "STKEYS2",
        ]
        names += [f"STFST{i}0" for i in range(5)]
        names += [f"{prefix}{i}" for prefix in ("STTNUM", "STYSNUM", "STGNUM") for i in range(10)]
        images = {}
        for name in names:
            image = _patch(lumps.get(name, b""), palette)
            if image is not None:
                images[name] = image
        return cls(images, maps, _pistol_wav(lumps.get("DSPISTOL", b"")))

    def _hud(self, health, armor, ammo, keys):
        yield "STBAR", 0, 168
        yield "STARMS", 104, 168
        for slot in range(6):
            prefix = "STYSNUM" if slot == 0 else "STGNUM"
            yield f"{prefix}{slot + 2}", 111 + slot % 3 * 12, 172 + slot // 3 * 10
        for slot, mask in enumerate((1, 4, 2)):
            if keys & mask:
                yield f"STKEYS{slot}", 239, 171 + 10 * slot
        tier = (100 - min(100, max(0, health))) * 5 // 101
        yield "STFDEAD0" if health <= 0 else f"STFST{tier}0", 143, 168
        for value, right, y, digits, width in (
            (ammo, 44, 171, "STTNUM", 14),
            (health, 90, 171, "STTNUM", 14),
            (armor, 221, 171, "STTNUM", 14),
            (ammo, 288, 173, "STYSNUM", 4),
        ):
            for place, digit in enumerate(reversed(str(max(0, min(999, value)))), 1):
                yield digits + digit, right - width * place, y
        for x in (90, 221):
            yield "STTPRCNT", x, 171

    def compose(self, world, *, health, armor, ammo, keys=0, shot_age=None):
        w, h = world.width, world.height
        if not self.has_status_bar and "PISGA0" not in self._images:
            return world
        view_h = 168 if self.has_status_bar else 200
        bottom = (h * view_h + 199) // 200
        gun, flash = "PISGA0", False
        if shot_age is not None and 0 <= shot_age < 8:
            gun = "PISGC0" if 3 <= shot_age < 6 else "PISGB0"
            flash = shot_age < 3
        key = w, h, health, armor, ammo, keys, gun, flash
        if key != self._overlay_key:
            runs = []
            if health > 0:
                # The weapon origin is offset from the center of the world viewport.
                origin = view_h // 2 - 100 + 32
                weapon = self._images.get(gun) or self._images.get("PISGA0")
                if weapon is not None:
                    runs.extend(_opaque_runs(weapon, 0, origin, w, h, bottom))
                if flash and "PISFA0" in self._images:
                    runs.extend(_opaque_runs(self._images["PISFA0"], 0, origin, w, h, bottom))
            if self.has_status_bar:
                for name, x, y in self._hud(health, armor, ammo, keys):
                    if name in self._images:
                        runs.extend(_opaque_runs(self._images[name], x, y, w, h, h))
            self._runs = runs
            self._overlay_key = key
        crop = (h - bottom) // 2 * w * 3
        canvas = bytearray(world.rgb[crop : crop + bottom * w * 3])
        canvas.extend(bytes((h - bottom) * w * 3))
        for start, pixels in self._runs:
            canvas[start : start + len(pixels)] = pixels
        return Image(w, h, bytes(canvas))
