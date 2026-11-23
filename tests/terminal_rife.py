import hashlib
import os
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from examples.terminal.art import Image
from examples.terminal.rife import Rife, _fetch


class RifeModelsTest(unittest.TestCase):
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
            self.assertEqual((image.width, image.height), (160, 100))
            rgb = np.frombuffer(image.rgb, dtype=np.uint8).reshape(100, 160, 3)
            centers.append(np.where(rgb[:, :, 0] > 120)[1].mean())
        for step in np.diff(centers):
            self.assertGreater(step, 1)
            self.assertLess(step, 7)
