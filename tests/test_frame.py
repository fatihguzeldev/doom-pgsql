from struct import pack
from unittest import TestCase

from client.frame import PIXELS, unpack_frame


def run(start, shade, colors, vertical=False):
    return pack('!HBB', start | (0x4000 if vertical else 0), len(colors), shade) + colors


class FrameTest(TestCase):
    def test_horizontal_and_vertical_runs_fill_one_image(self):
        payload = run(0, 5, bytes(range(100)), vertical=True)
        payload += b''.join(run(y * 160 + 1, 2, b'\x21' * 159) for y in range(100))
        colors, shades = unpack_frame(payload)
        self.assertEqual(colors[::160], bytes(range(100)))
        self.assertEqual(shades[::160], b'\x05' * 100)
        self.assertEqual(colors[159::160], b'\x21' * 100)
        self.assertEqual(shades[159::160], b'\x02' * 100)

    def test_holes_and_overlap_are_rejected(self):
        frame = b''.join(run(y * 160, 0, b'\x01' * 160) for y in range(100))
        for payload in (frame[:-164], frame + run(0, 0, b'\x01'), frame[:-164] + frame[:164]):
            with self.assertRaises(ValueError):
                unpack_frame(payload)
        self.assertEqual(len(unpack_frame(frame)[0]), PIXELS)

    def test_bounds_and_truncated_headers_are_rejected(self):
        for payload in (b'\x00', run(159, 0, b'\x01\x01'), run(15840, 0, b'\x01\x01', vertical=True),
                        run(0x8000, 0, b'\x01'), run(0, 0, b''), run(0, 0, b'\x01\x02')[:-1]):
            with self.assertRaises(ValueError):
                unpack_frame(payload)
