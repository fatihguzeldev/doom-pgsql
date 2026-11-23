"""Interpolate the 64×40 SQL image and expand its pixels onto Doom's 320×200 canvas."""

import hashlib
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
        if (image.width, image.height) != (64, 40):
            raise ValueError("RIFE expects a 64x40 RGB frame")
        return self._np.frombuffer(image.rgb, dtype=self._np.uint8).reshape(40, 64, 3)

    def _tensor(self, rgb):
        # This RIFE export requires both dimensions to be multiples of 64.
        padded = self._np.pad(rgb, ((0, 24), (0, 0), (0, 0)), mode="edge")
        return padded.transpose(2, 0, 1)[None].astype(self._np.float32) / 255

    @staticmethod
    def _upscale(rgb):
        pixels = rgb.repeat(5, axis=0).repeat(5, axis=1)
        return Image(320, 200, pixels.tobytes())

    def upscale(self, image):
        return self._upscale(self._rgb(image))

    def infer_pair(self, first, second):
        a, b = self._rgb(first), self._rgb(second)
        inputs = {"img0": self._tensor(a), "img1": self._tensor(b)}
        frames = []
        for timestep in self._times:
            inputs["timestep"] = timestep
            predicted = self._net.run(["frame"], inputs)[0][0, :, :40, :64]
            rgb = (
                (predicted.transpose(1, 2, 0).clip(0, 1) * 255)
                .round()
                .astype(self._np.uint8)
            )
            frames.append(self._upscale(rgb))
        return (*frames, self._upscale(b))


if __name__ == "__main__":
    model_path()
