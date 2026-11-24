import hashlib
import importlib.util
import os
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from client.art import Image
from client.rife import Rife, _fetch


class RifeModelsTest(unittest.TestCase):
    @unittest.skipUnless(importlib.util.find_spec("numpy"), "requires numpy")
    def test_upscale_keeps_source_colors_and_cuts_diagonal_corners(self):
        import numpy as np

        pixels = np.zeros((40, 64, 3), dtype=np.uint8)
        ink = (220, 160, 100)
        pixels[10, 11] = pixels[11, 10] = ink
        pixels[20, 20] = ink
        image = Rife._upscale(pixels)
        rgb = np.frombuffer(image.rgb, dtype=np.uint8).reshape(200, 320, 3)
        np.testing.assert_array_equal(rgb[2::5, 2::5], pixels)
        expected = np.zeros((5, 5, 3), dtype=np.uint8)
        expected[0, :2] = expected[1, 0] = ink
        np.testing.assert_array_equal(rgb[55:60, 55:60], expected)
        self.assertTrue((rgb[100:105, 100:105] == ink).all())
        self.assertTrue(((rgb == 0).all(axis=2) | (rgb == ink).all(axis=2)).all())

    def test_verified_download_recovers_from_corrupt_cache(self):
        with TemporaryDirectory() as temp:
            root = Path(temp)
            origin = root / "weights"
            origin.write_bytes(b"model")
            cache = root / "cache"
            cache.mkdir()
            digest = hashlib.sha256(b"model").hexdigest()
            args = (cache, origin.as_uri(), digest)
            model = _fetch(*args)
            model.write_bytes(b"damaged")
            self.assertEqual(_fetch(*args).read_bytes(), b"model")
            origin.unlink()
            self.assertEqual(_fetch(*args), model)

    def test_rejects_bad_download_before_installing_it(self):
        with TemporaryDirectory() as temp:
            root = Path(temp)
            origin = root / "weights"
            origin.write_bytes(b"wrong model")
            cache = root / "cache"
            cache.mkdir()
            with self.assertRaisesRegex(ValueError, "checksum"):
                _fetch(cache, origin.as_uri(), "0" * 64)
            self.assertEqual(list(cache.iterdir()), [])

    @unittest.skipUnless(
        os.environ.get("RIFE_TEST_MODELS"),
        "set RIFE_TEST_MODELS to the model directory",
    )
    def test_interpolates_a_translated_object_and_preserves_the_anchor(self):
        import numpy as np

        net = Rife(os.environ["RIFE_TEST_MODELS"])
        pixels = np.zeros((40, 64, 3), dtype=np.uint8)
        pixels[10:27, 14:26] = (220, 160, 100)
        first = Image(64, 40, pixels.tobytes())
        last = Image(64, 40, np.roll(pixels, 8, axis=1).tobytes())

        frames = (net.upscale(first), *net.infer_pair(first, last))
        self.assertEqual(len(frames), 6)
        self.assertEqual(frames[-1], net.upscale(last))
        centers = []
        for image in frames:
            self.assertEqual((image.width, image.height), (320, 200))
            blocks = np.frombuffer(image.rgb, dtype=np.uint8).reshape(40, 5, 64, 5, 3)
            centers.append(np.where(blocks[:, 2, :, 2, 0] > 120)[1].mean())
        np.testing.assert_array_equal(blocks[:, 2, :, 2], np.roll(pixels, 8, axis=1))
        for step in np.diff(centers):
            self.assertGreater(step, 0.4)
            self.assertLess(step, 2.8)

        native = np.zeros((100, 160, 3), dtype=np.uint8)
        native[71:96, 108:130] = (220, 160, 100)
        first = Image(160, 100, native.tobytes())
        shifted = np.roll(native, 9, axis=1)
        last = Image(160, 100, shifted.tobytes())
        views = (net.upscale(first), *net.infer_pair(first, last))
        actual = [
            np.frombuffer(view.rgb, dtype=np.uint8).reshape(200, 320, 3)
            for view in views
        ]
        np.testing.assert_array_equal(actual[-1], shifted.repeat(2, 0).repeat(2, 1))
        centers = [np.where(rgb[::2, ::2, 0] > 120)[1].mean() for rgb in actual]
        self.assertTrue((np.diff(centers) > 0).all())
        with self.assertRaisesRegex(ValueError, "matching dimensions"):
            net.infer_pair(Image(64, 40, pixels.tobytes()), last)

        rgb = native[39:, 63:]
        first = Image(97, 61, rgb.tobytes())
        last = Image(97, 61, np.roll(rgb, 3, axis=1).tobytes())
        frames = net.infer_pair(first, last)
        self.assertEqual(frames[-1], net.upscale(last))
        self.assertTrue(all((f.width, f.height) == (388, 244) for f in frames))
