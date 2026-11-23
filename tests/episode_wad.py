"""Render all nine shareware maps and replay the Hangar exit route."""

import argparse
import hashlib
import json
import math
from pathlib import Path

import psycopg
from psycopg.types.json import Jsonb


def verify(wad_path):
    wad = wad_path.read_bytes()
    if hashlib.md5(wad).hexdigest() != "f0cefca49926d00903cf57551d901abe":
        raise ValueError("the recorded exit route requires the DOOM v1.9 shareware IWAD")
    groups = json.loads((Path(__file__).parent / "fixtures/e1m1-exit.json").read_text())
    with psycopg.connect(autocommit=True) as db:
        for i in range(1, 10):
            name = f"E1M{i}"
            (level,) = db.execute("SELECT doom.load_wad(%s,%s)", (wad, name)).fetchone()
            game, epoch, _ = db.execute("SELECT * FROM doom.new_game(%s)", (level,)).fetchone()
            headings = set()
            for n in range(1, 9):
                db.execute("SELECT doom.tick(%s,%s,%s,0,0,%s,false,false)", (game, epoch, n, math.pi / 4))
                w, h, indices, shades = db.execute(
                    "SELECT width,height,pixels,shades FROM doom.frame(%s,%s,%s)",
                    (game, epoch, n),
                    binary=True,
                ).fetchone()
                assert len(indices) == len(shades) == w * h == 16000 and len(set(indices)) > 8
                headings.add(hashlib.blake2s(indices + shades).digest())
            assert len(headings) == 8, name
            if i != 1:
                continue
            game, epoch, _ = db.execute("SELECT * FROM doom.new_game(%s,1)", (level,)).fetchone()
            commands = []
            for count, forward, turn in groups:
                for _ in range(count):
                    commands.append([forward, 0, turn, True, (len(commands) + 1) % 8 == 0])
            for first in range(0, len(commands), 12):
                (ack,) = db.execute(
                    "CALL doom.submit(%s,%s,%s,%s)",
                    (game, epoch, first + 1, Jsonb(commands[first : first + 12])),
                ).fetchone()
            assert ack == len(commands) == 683
            assert db.execute("SELECT finished FROM doom.game_status(%s)", (game,)).fetchone() == (True,)
            print(f"{name} reached its exit at tic {ack}")
    print("E1M1–E1M9 each produced eight distinct 160x100 images")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wad", type=Path)
    verify(parser.parse_args().wad)
