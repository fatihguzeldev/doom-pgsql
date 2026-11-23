import math
import re
import unittest

from client.automap import UNITS_PER_DOT, Automap, _line_dots

SGR = re.compile(r"\x1b\[[\d;]*m")


class AutomapTest(unittest.TestCase):
    def test_north_up_movement_and_heading(self):
        d = UNITS_PER_DOT
        automap = Automap([(-6 * d, 4 * d, 6 * d, 4 * d, "wall")])
        initial = [SGR.sub("", row) for row in automap.rows(0, 0, 0, 7, 3)]
        self.assertEqual(initial[0], "⠠⠤⠤⠤⠤⠤⠤")
        self.assertEqual(initial[1], "   →   ")
        self.assertEqual(initial[2], "       ")
        moved = [SGR.sub("", row) for row in automap.rows(0, 4 * d, math.pi / 2, 7, 3)]
        self.assertEqual(moved[0], "       ")
        self.assertEqual(moved[1], "⠠⠤⠤↑⠤⠤⠤")
        self.assertEqual(moved[2], "       ")

    def test_tiny_view_and_long_or_reversed_walls(self):
        bounds = (-3, -3, 3, 3)
        for a, b in [
            ((-100000, -100000), (100000, 100000)),
            ((1, -100000), (1, 100000)),
            ((0, 0), (0, 0)),
            ((100, 0), (100, 100)),
        ]:
            dots = list(_line_dots(*a, *b, *bounds))
            self.assertEqual(dots, list(_line_dots(*b, *a, *bounds)))
            self.assertLessEqual(len(dots), 7)
        automap = Automap([])
        self.assertEqual(
            [SGR.sub("", row) for row in automap.rows(0, 0, -math.pi / 4, 1, 1)], ["↘"]
        )
        self.assertEqual(automap.rows(0, 0, 0, 0, 3), ["", "", ""])
