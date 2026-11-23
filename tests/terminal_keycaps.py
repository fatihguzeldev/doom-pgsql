import io
import os
import re
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch

from examples.terminal.art import Image
from examples.terminal.display import (
    KEY_AMBER,
    KEY_CYAN,
    KEY_FACE,
    KEY_INK,
    SGR,
    Display,
    _cells,
    _control_rows,
)


def key_positions(rows):
    faces = (KEY_FACE, KEY_CYAN + KEY_INK, KEY_AMBER + KEY_INK)
    pattern = re.compile("(" + "|".join(map(re.escape, faces)) + ")([^\x1b]+)")
    positions = {}
    for y, (_, row) in enumerate(rows):
        for match in pattern.finditer(row):
            face, label = match.groups()
            x = _cells(SGR.sub("", row[: match.start()]))
            positions[label.strip()] = (x, y, _cells(label), face)
    return positions


WORLD = Image(8, 5, bytes((3, 5, 7)) * 40)
STATUS = {"map": "E1M1", "game": 1, "health": 100, "armor": 0, "ammo": 50}


class KeycapsTest(unittest.TestCase):
    def test_physical_keys_and_combinations(self):
        pressed = {"w", "a", "right", "l", " ", "e"}
        for width in (58, 78, 114):
            with self.subTest(width=width):
                keys = key_positions(_control_rows(width, False, pressed))
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
            idle = _control_rows(width, False, ())
            latched = _control_rows(width, True, ())
            self.assertEqual(key_positions(idle), key_positions(latched), width)
            self.assertEqual([w for w, _ in idle], [w for w, _ in latched], width)
            for row_width, line in latched:
                self.assertEqual(row_width, _cells(SGR.sub("", line)))
                self.assertLessEqual(row_width, width)
            if width >= 58:
                self.assertIn("AUTO-WALK", latched[-1][1])

    def test_press_and_release_repaint_only_the_controls(self):
        display = Display()
        with patch("shutil.get_terminal_size", return_value=os.terminal_size((80, 24))):
            with redirect_stdout(io.StringIO()) as initial:
                display.paint(WORLD, STATUS)
            self.assertIn("HP 100%", initial.getvalue())
            self.assertIn("FPS 0.0", initial.getvalue())
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
                self.assertNotIn("HP 100%", update.getvalue())

    def test_viewport_stays_centered_above_controls(self):
        display = Display()
        for width, height in ((60, 20), (80, 24), (116, 42)):
            size = os.terminal_size((width, height))
            with patch("shutil.get_terminal_size", return_value=size), redirect_stdout(io.StringIO()):
                display.paint(WORLD, STATUS, lit_keys={"left", " "})
            world = [
                (x, y, _cells(SGR.sub("", line)))
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
            self.assertEqual([SGR.sub("", line) for _, line in header[-2]], ["FPS 0.0"])
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
