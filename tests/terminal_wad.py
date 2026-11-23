"""Test SQL edits and terminal input on E1M3."""

import argparse
import fcntl
import os
import pty
import select
import struct
import subprocess
import sys
import termios
import time
from pathlib import Path

import psycopg
from psycopg.types.json import Jsonb


def read_until(fd, marker, timeout=10):
    output = bytearray()
    end = time.monotonic() + timeout
    while marker not in output:
        wait = end - time.monotonic()
        if wait <= 0 or not select.select([fd], [], [], wait)[0]:
            raise AssertionError(f"terminal did not emit {marker!r}")
        output.extend(os.read(fd, 65536))
    return bytes(output)


def run(wad):
    with psycopg.connect(autocommit=True) as editor, psycopg.connect(autocommit=True) as observer:
        level = editor.execute("SELECT doom.load_wad(%s,'E1M3')", (wad.read_bytes(),)).fetchone()[0]
        game, epoch, _ = editor.execute("SELECT * FROM doom.new_game(%s)", (level,)).fetchone()
        # Retry both tics after the first commits.
        cmds = [[1, 0, 0, False, False], [0, 0, 0.2, False, False]]
        editor.execute("CALL doom.submit(%s,%s,1,%s)", (game, epoch, Jsonb(cmds[:1])))
        editor.execute("CALL doom.submit(%s,%s,1,%s)", (game, epoch, Jsonb(cmds)))
        assert observer.execute("SELECT tic FROM doom.game_status(%s)", (game,)).fetchone() == (2,)

        def poll(token=None):
            return observer.execute(
                "SELECT pixels,token FROM doom.poll_frame(%s,%s,1,%s)", (game, epoch, token), binary=True
            ).fetchone()

        first, token = poll()
        with editor.transaction():
            editor.execute("UPDATE doom.actors SET yaw=yaw+1 WHERE game=%s AND id=-1", (game,))
            assert poll(token)[0] is None
        fresh, next_token = poll(token)
        assert len(fresh) == 16000 and first != fresh and next_token != token
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 80, 0, 0))
        cmd = [
            sys.executable,
            "-B",
            "-m",
            "examples.terminal.play",
            "--game",
            str(game),
            "--delta",
            "--predict-turn",
        ]
        try:
            proc = subprocess.Popen(cmd, stdin=slave, stdout=slave, stderr=slave)
            try:
                data = read_until(master, b"AMMO ")
                assert "▀".encode() in data and b"38;2;" in data and b"48;2;" in data
                old = editor.execute(
                    "SELECT yaw FROM doom.actors WHERE game=%s AND id=-1", (game,)
                ).fetchone()
                os.write(master, b"j")
                end = time.monotonic() + 5
                while (
                    editor.execute("SELECT yaw FROM doom.actors WHERE game=%s AND id=-1", (game,)).fetchone()
                    == old
                ):
                    if time.monotonic() >= end:
                        raise AssertionError("terminal input did not reach the database")
                    if select.select([master], [], [], 0.02)[0]:
                        os.read(master, 65536)
                os.write(master, b"q")
                read_until(master, b"\x1b[?1049l")
                assert proc.wait(timeout=5) == 0
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait()
        finally:
            os.close(master)
            os.close(slave)
    print("E1M3 terminal test passed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wad", type=Path)
    run(parser.parse_args().wad)
