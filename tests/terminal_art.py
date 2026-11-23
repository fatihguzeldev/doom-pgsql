import io
import struct
import unittest
import wave
from pathlib import Path

from examples.terminal.art import Art, Image


def wad(*lumps):
    data, directory = bytearray(), bytearray()
    for name, content in lumps:
        directory.extend(struct.pack("<II8s", 12 + len(data), len(content), name.encode()))
        data.extend(content)
    return b"PWAD" + struct.pack("<II", len(lumps), 12 + len(data)) + data + directory


class TerminalArtTest(unittest.TestCase):
    def test_patch_posts_transparency_and_palette(self):
        palette = bytes([1, 2, 3, 51, 52, 53]) + bytes(762)
        # Column zero starts on row one, column one contains both pixels.
        pic = struct.pack("<HHhhII", 2, 2, -1, 3, 16, 22)
        pic += bytes([1, 1, 0, 1, 0, 255, 0, 2, 0, 0, 1, 0, 255])
        art = Art.from_bytes(wad(("PLAYPAL", palette), ("M_SKULL1", pic), ("TITLEPIC", pic[:-1])))
        image = art.skull
        self.assertEqual((image.left, image.top), (-1, 3))
        self.assertEqual(image.alpha, bytes([0, 255, 255, 255]))
        self.assertEqual(image.rgb[3:], bytes([1, 2, 3, 51, 52, 53, 51, 52, 53]))
        self.assertIsNone(art.title)
        self.assertIsNone(art.pistol_sound)
        self.assertIs(art.compose(image, health=1, armor=0, ammo=0), image)

    def test_shareware_art_and_sound(self):
        art = Art.from_bytes((Path(__file__).resolve().parents[1] / "assets/doom1.wad").read_bytes())
        self.assertEqual(art.maps, tuple(f"E1M{i}" for i in range(1, 10)))
        self.assertEqual((art.title.width, art.title.height), (320, 200))
        with wave.open(io.BytesIO(art.pistol_sound)) as sound:
            self.assertEqual(
                (sound.getnchannels(), sound.getsampwidth(), sound.getframerate()), (1, 1, 11025)
            )
            self.assertEqual(len(sound.readframes(sound.getnframes())), 5629)

        w, h = 160, 100
        background = b"".join(bytes([y]) * w * 3 for y in range(h))
        world = Image(w, h, background)
        idle = art.compose(world, health=100, armor=0, ammo=50)
        fire = art.compose(world, health=100, armor=0, ammo=50, shot_age=0)
        hurt = art.compose(world, health=40, armor=40, ammo=7)
        bar = 84 * w * 3
        self.assertEqual(idle.rgb[: 30 * w * 3], background[8 * w * 3 : 38 * w * 3])
        self.assertNotEqual(idle.rgb[:bar], fire.rgb[:bar])
        self.assertEqual(idle.rgb[bar:], fire.rgb[bar:])
        self.assertEqual(idle.rgb[:bar], hurt.rgb[:bar])
        self.assertNotEqual(idle.rgb[bar:], hurt.rgb[bar:])
        self.assertEqual(art.compose(world, health=100, armor=0, ammo=50, shot_age=8), idle)
        self.assertEqual(world.rgb, background)
