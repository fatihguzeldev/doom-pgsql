import base64
import io
import math
import os
import re
import struct
import unittest
import zlib
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

from client.ansi import SGR, cell_width, image_rows
from client.art import Art, Image
from client.automap import Automap
from client.display import Display
from client.widgets import (
    KEY_AMBER,
    KEY_CYAN,
    KEY_FACE,
    KEY_INK,
    control_rows,
)


def key_positions(rows):
    faces = (KEY_FACE, KEY_CYAN + KEY_INK, KEY_AMBER + KEY_INK)
    pattern = re.compile("(" + "|".join(map(re.escape, faces)) + ")([^\x1b]+)")
    positions = {}
    for y, (_, row) in enumerate(rows):
        for match in pattern.finditer(row):
            face, label = match.groups()
            x = cell_width(SGR.sub("", row[: match.start()]))
            positions[label.strip()] = (x, y, cell_width(label), face)
    return positions


WORLD = Image(8, 5, bytes((3, 5, 7)) * 40)
STATUS = {"map": "E1M1", "game": 1, "health": 100, "armor": 0, "ammo": 50}


class KeycapsTest(unittest.TestCase):
    def test_hud_keeps_its_detail_and_updates_without_a_new_frame(self):
        art = Art.from_bytes((Path(__file__).resolve().parents[1] / "assets/doom1.wad").read_bytes())
        with patch.dict(os.environ, {"TERM_PROGRAM": "iTerm.app", "TMUX": "", "TERM": "xterm-256color"}):
            display = Display(art)
        map_args = {"automap": Automap([]), "pose": (0, 0, 0)}
        with patch("shutil.get_terminal_size", return_value=os.terminal_size((136, 41))):
            for i, (w, h) in enumerate(((64, 40), (160, 100), (320, 200))):
                world = Image(w, h, bytes((3, 5, 7)) * (w * h))
                with redirect_stdout(io.StringIO()) as output:
                    display.paint(world, STATUS, **map_args)
                self.assertEqual("]1337;File=" in output.getvalue(), i == 0)
            x, y, sequence = display._overlay
            width, height, payload = re.search(r"width=(\d+);height=(\d+);preserveAspectRatio=0:(.+)\a", sequence).groups()
            png = base64.b64decode(payload)
            self.assertEqual(png[:8], b"\x89PNG\r\n\x1a\n")
            self.assertEqual(struct.unpack_from(">II", png, 16), (320, 32))
            compressed = png[41:41 + struct.unpack_from(">I", png, 33)[0]]
            scanlines = zlib.decompress(compressed)
            expected = art.status_bar(100, 0, 50, 0)
            self.assertEqual(scanlines, b"".join(b"\0" + expected.rgb[i:i + 960] for i in range(0, len(expected.rgb), 960)))
            last_world_row = next(line for col, line in display._previous[y - 1] if col == x)
            self.assertEqual(cell_width(SGR.sub("", last_world_row)), int(width))
            self.assertGreaterEqual(int(height), 3)
            with redirect_stdout(io.StringIO()) as update:
                display.paint(world, dict(STATUS, health=37, armor=25, ammo=47, keys=5), **map_args)
            self.assertIn("]1337;File=", update.getvalue())
            self.assertNotEqual(sequence, display._overlay[2])
            self.assertNotIn("48;2;3;5;7m", update.getvalue())

            with redirect_stdout(io.StringIO()) as menu:
                display.menu("Paused", ["Resume"])
            for row in range(y + 1, y + int(height) + 1):
                self.assertIn(f"\x1b[{row};1H", menu.getvalue())
            with redirect_stdout(io.StringIO()) as resume:
                display.paint(world, STATUS, **map_args)
            self.assertIn(sequence, resume.getvalue())

        with patch("shutil.get_terminal_size", return_value=os.terminal_size((80, 24))), redirect_stdout(io.StringIO()) as resized:
            display.paint(world, STATUS, **map_args)
        self.assertIn("]1337;File=", resized.getvalue())
        self.assertNotEqual(sequence, display._overlay[2])

    def test_status_bar_uses_wad_pixels_on_ansi_terminals(self):
        art = Art.from_bytes((Path(__file__).resolve().parents[1] / "assets/doom1.wad").read_bytes())
        with patch.dict(os.environ, {"TERM_PROGRAM": ""}):
            display = Display(art)
        with patch("shutil.get_terminal_size", return_value=os.terminal_size((136, 41))), redirect_stdout(io.StringIO()):
            display.paint(WORLD, STATUS, automap=Automap([]), pose=(0, 0, 0))
        world_rows = [(x, y, cell_width(SGR.sub("", line))) for y, row in enumerate(display._previous)
                      for x, line in row if "48;2;3;5;7m" in line]
        x, y, width = world_rows[-1]
        expected = image_rows(art.status_bar(100, 0, 50, 0), width, round(width / 20))
        for i, row in enumerate(expected, 1):
            self.assertIn((x, row), display._previous[y + i])

    def test_automap_sits_outside_the_view_and_hud(self):
        automap = Automap([(-48, -48, 48, -48, "wall")])
        for width, height in ((42, 27), (60, 20), (80, 24), (144, 44)):
            display = Display()
            with self.subTest(size=(width, height)), patch(
                "shutil.get_terminal_size", return_value=os.terminal_size((width, height))
            ), redirect_stdout(io.StringIO()):
                display.paint(WORLD, STATUS, automap=automap, pose=(0, 0, math.pi / 4))
                plain = []
                for row in display._previous:
                    right = 0
                    for x, styled in sorted(row):
                        text = SGR.sub("", styled)
                        self.assertGreaterEqual(x, right)
                        right = x + cell_width(text)
                        self.assertLessEqual(right, width)
                        plain.append(text)
                self.assertTrue(any("AUTOMAP" in s for s in plain))
                self.assertTrue(any("↗" in s for s in plain))
                self.assertIn("AMMO", " ".join(plain))
                self.assertIn("100%", " ".join(plain))

    def test_physical_keys_and_combinations(self):
        pressed = {"w", "a", "right", "l", " ", "e"}
        for width in (58, 78, 114):
            with self.subTest(width=width):
                keys = key_positions(control_rows(width, False, pressed))
                self.assertEqual(set(keys), set("WASDJLERQ") | {"↑", "↓", "←", "→", "SPACE", "Esc"})
                for top, left, center, right in (("W", "A", "S", "D"), ("↑", "←", "↓", "→")):
                    self.assertEqual(keys[top][0], keys[center][0])
                    self.assertEqual(keys[top][1] + 1, keys[center][1])
                    self.assertLess(keys[left][0], keys[center][0])
                    self.assertLess(keys[center][0], keys[right][0])
                self.assertGreater(keys["SPACE"][2], 2 * keys["W"][2])
                for label, (_, _, _, face) in keys.items():
                    if label in ("W", "A", "→", "L"):
                        self.assertEqual(face, KEY_CYAN + KEY_INK)
                    elif label in ("SPACE", "E"):
                        self.assertEqual(face, KEY_AMBER + KEY_INK)
                    else:
                        self.assertEqual(face, KEY_FACE)

    def test_latched_auto_walk_keeps_key_positions(self):
        for width in range(1, 135):
            idle = control_rows(width, False, ())
            latched = control_rows(width, True, ())
            self.assertEqual(key_positions(idle), key_positions(latched), width)
            self.assertEqual([w for w, _ in idle], [w for w, _ in latched], width)
            for row_width, line in latched:
                self.assertEqual(row_width, cell_width(SGR.sub("", line)))
                self.assertLessEqual(row_width, width)
            if width >= 58:
                self.assertIn("AUTO-WALK", latched[-1][1])

    def test_press_and_release_repaint_only_the_controls(self):
        display = Display()
        with patch("shutil.get_terminal_size", return_value=os.terminal_size((80, 24))):
            with redirect_stdout(io.StringIO()) as initial:
                display.paint(WORLD, STATUS)
            self.assertIn("100%", initial.getvalue())
            self.assertIn("FPS 0", initial.getvalue())
            with redirect_stdout(io.StringIO()) as down:
                display.paint(WORLD, STATUS, lit_keys={"w", " "})
            self.assertIn(KEY_CYAN, down.getvalue())
            self.assertIn(KEY_AMBER, down.getvalue())
            with redirect_stdout(io.StringIO()) as released:
                display.paint(WORLD, STATUS)
            self.assertIn(KEY_FACE, released.getvalue())
            self.assertNotIn(KEY_CYAN, released.getvalue())
            for update in (down, released):
                self.assertNotIn("48;2;3;5;7m", update.getvalue())
                self.assertNotIn("100%", update.getvalue())

    def test_single_fps_label_keeps_only_meaningful_decimals(self):
        display = Display()
        with patch("shutil.get_terminal_size", return_value=os.terminal_size((80, 24))):
            for fps, expected in ((None, "FPS —"), (12.0, "FPS 12"), (5.83, "FPS 5.8")):
                with redirect_stdout(io.StringIO()):
                    display.paint(WORLD, STATUS, fps=fps)
                labels = [SGR.sub("", line) for row in display._previous for _, line in row if "FPS" in line]
                self.assertEqual(labels, [expected])

    def test_viewport_stays_centered_above_controls(self):
        display = Display()
        for width, height in ((60, 20), (80, 24), (116, 42)):
            size = os.terminal_size((width, height))
            with patch("shutil.get_terminal_size", return_value=size), redirect_stdout(io.StringIO()):
                display.paint(WORLD, STATUS, lit_keys={"left", " "})
            world = [
                (x, y, cell_width(SGR.sub("", line)))
                for y, row in enumerate(display._previous)
                for x, line in row
                if "48;2;3;5;7m" in line
            ]
            left, top, cols = world[0]
            self.assertGreaterEqual(len(world), height // 2)
            self.assertLessEqual(abs(left - (width - left - cols)), 1)
            self.assertLessEqual(abs(top - (height - top - len(world))), 1)
            header = display._previous[:top]
            self.assertFalse(header[-1])
            self.assertEqual([SGR.sub("", line) for _, line in header[-2]], ["FPS 0"])
            if height >= 22:
                self.assertFalse(header[-3])

    def test_logo_moves_while_the_world_and_counter_stay_still(self):
        display = Display()
        for size in ((80, 24), (116, 42)):
            with patch("shutil.get_terminal_size", return_value=os.terminal_size(size)):
                with redirect_stdout(io.StringIO()):
                    display.paint(WORLD, STATUS, phase=0)
                first_page = display._previous
                with redirect_stdout(io.StringIO()) as update:
                    display.paint(WORLD, STATUS, phase=10)
                moved = [(a, b) for a, b in zip(first_page, display._previous) if a != b]
                self.assertTrue(moved)
                for before, after in moved:
                    self.assertEqual(after[0][0] - before[0][0], 2)
                self.assertNotIn("FPS", update.getvalue())
                self.assertNotIn("48;2;3;5;7m", update.getvalue())


if __name__ == "__main__":
    unittest.main()
