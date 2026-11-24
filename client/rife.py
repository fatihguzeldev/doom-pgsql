import hashlib
import math
import os
import shutil
from pathlib import Path
from tempfile import NamedTemporaryFile
from urllib.request import urlopen

from .art import Image

RIFE = (
    (
        "https://huggingface.co/t9749/rife-4.25-lite-onnx/resolve/"
        "8d1488a82e19fd2f2ca5b3ee1d1bfacd6787b9df/rife_v425lite.onnx"
    ),
    "702802d0862ab78f2d72133c6bc3768e7e89b81756f7cd51d1055a2fe3d06577",
)


def _digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def _fetch(directory, url, sha256):
    path = directory / url.rsplit("/", 1)[-1]
    if path.is_file() and _digest(path) == sha256:
        return path
    with NamedTemporaryFile(dir=directory, delete=False) as output:
        temporary = Path(output.name)
    try:
        with urlopen(url, timeout=60) as source, temporary.open("wb") as output:
            shutil.copyfileobj(source, output)
        if _digest(temporary) != sha256:
            raise ValueError(f"checksum mismatch for {path.name}")
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)
    return path


def model_path(directory=None):
    if directory is None:
        directory = (
            Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache")
            / "doom-pgsql"
        )
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    return _fetch(directory, *RIFE)


class Rife:
    def __init__(self, model_dir=None):
        import numpy as np
        import onnxruntime as ort

        self._np = np
        options = ort.SessionOptions()
        options.intra_op_num_threads = 2
        options.inter_op_num_threads = 1
        options.add_session_config_entry("session.intra_op.allow_spinning", "0")
        self._net = ort.InferenceSession(
            str(model_path(model_dir)), options, providers=["CPUExecutionProvider"]
        )
        self._times = [
            np.full((1, 1, 1, 1), n / 5, dtype=np.float32) for n in range(1, 5)
        ]

    def _rgb(self, image):
        return self._np.frombuffer(image.rgb, dtype=self._np.uint8).reshape(
            image.height, image.width, 3
        )

    def _tensor(self, rgb):
        # the model requires dimensions divisible by 64
        h, w = rgb.shape[:2]
        padded = self._np.pad(rgb, ((0, -h % 64), (0, -w % 64), (0, 0)), mode="edge")
        return padded.transpose(2, 0, 1)[None].astype(self._np.float32) / 255

    @staticmethod
    def _upscale(rgb):
        import numpy as np

        h, w = rgb.shape[:2]
        scale = max(1, math.ceil(min(320 / w, 200 / h)))
        pixels = rgb if scale == 1 else rgb.repeat(scale, axis=0).repeat(scale, axis=1)
        if (w, h) != (64, 40):
            return Image(w * scale, h * scale, pixels.tobytes())
        blocks = pixels.reshape(h, 5, w, 5, 3)
        padded = np.pad(rgb, ((1, 1), (1, 1), (0, 0)), mode="edge")
        top, bottom = padded[:-2, 1:-1], padded[2:, 1:-1]
        left, right = padded[1:-1, :-2], padded[1:-1, 2:]
        bend = (top != bottom).any(axis=2) & (left != right).any(axis=2)

        # scale2x's corner rule, limited to three samples of each 5×5 block
        for y, inner_y, vertical in ((0, 1, top), (4, 3, bottom)):
            for x, inner_x, horizontal in ((0, 1, left), (4, 3, right)):
                corner = (bend & (vertical == horizontal).all(axis=2))[..., None]
                for row, col in ((y, x), (inner_y, x), (y, inner_x)):
                    np.copyto(blocks[:, row, :, col], vertical, where=corner)
        return Image(320, 200, pixels.tobytes())

    def upscale(self, image):
        return self._upscale(self._rgb(image))

    def infer_pair(self, first, second):
        a, b = self._rgb(first), self._rgb(second)
        if a.shape != b.shape:
            raise ValueError("RIFE frames must have matching dimensions")
        h, w = a.shape[:2]
        inputs = {"img0": self._tensor(a), "img1": self._tensor(b)}
        frames = []
        for timestep in self._times:
            inputs["timestep"] = timestep
            predicted = self._net.run(["frame"], inputs)[0][0, :, :h, :w]
            rgb = (
                (predicted.transpose(1, 2, 0).clip(0, 1) * 255)
                .round()
                .astype(self._np.uint8)
            )
            frames.append(self._upscale(rgb))
        return (*frames, self._upscale(b))


if __name__ == "__main__":
    model_path()
