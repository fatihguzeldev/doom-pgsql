import os
import shutil
import subprocess
import sys
import tempfile
from contextlib import contextmanager
from pathlib import Path


def terminal_bell():
    sys.stdout.write("\a")
    sys.stdout.flush()


@contextmanager
def pistol_sound(wav, muted):
    if muted:
        yield lambda: None
        return

    bridge = os.environ.get("DOOM_AUDIO_DIR")
    if bridge and wav:
        directory = Path(bridge)
        (directory / "pistol.wav").write_bytes(wav)
        with (directory / "shots").open("a", buffering=1) as cues:
            yield lambda: cues.write("fire\n")
        return

    player = next((exe for exe in ("afplay", "paplay", "aplay") if shutil.which(exe)), None)
    if not player or not wav:
        yield terminal_bell
        return

    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "pistol.wav"
        path.write_bytes(wav)
        voices = []

        def fire():
            voices[:] = [proc for proc in voices if proc.poll() is None]
            voices.append(
                subprocess.Popen(
                    [player, str(path)],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
            )

        try:
            yield fire
        finally:
            for proc in voices:
                if proc.poll() is None:
                    proc.terminate()
                proc.wait()
