"""Play, pause and reload a fresh game through a PTY in an installed test database."""

import os
import pty
import re
import select
import subprocess
import sys
import termios
import time
from contextlib import contextmanager

import psycopg


class Terminal:
    def __init__(self, fd):
        self.fd = fd
        self.buffer = b""

    def send(self, keys):
        os.write(self.fd, keys)

    def until(self, pattern, timeout=10):
        end = time.monotonic() + timeout
        while not (match := re.search(pattern, self.buffer)):
            wait = end - time.monotonic()
            if wait <= 0 or not select.select([self.fd], [], [], wait)[0]:
                raise AssertionError(f"missing {pattern!r}, last output: {self.buffer[-180:]!r}")
            chunk = os.read(self.fd, 65536)
            if not chunk:
                raise AssertionError(f"terminal closed before {pattern!r}")
            self.buffer += chunk
        output, self.buffer = self.buffer[: match.end()], self.buffer[match.end() :]
        return output

    def quit(self, proc):
        self.send(b"q")
        self.until(rb"\x1b\[\?1049l", timeout=2)
        assert proc.wait(timeout=2) == 0


@contextmanager
def client(*args):
    master, slave = pty.openpty()
    try:
        termios.tcsetwinsize(slave, (30, 96))
        cmd = [sys.executable, "-B", "-m", "examples.terminal.play", "--mute", *args]
        env = {k: v for k, v in os.environ.items() if k not in ("COLUMNS", "LINES")}
        with subprocess.Popen(cmd, stdin=slave, stdout=slave, stderr=slave, env=env) as proc:
            try:
                yield Terminal(master), proc
            finally:
                if proc.poll() is None:
                    proc.kill()
    finally:
        os.close(master)
        os.close(slave)


def resize_game(tty, rows, cols):
    termios.tcsetwinsize(tty.fd, (rows, cols))
    tty.until(rb"\x1b\[2J")
    redraw = tty.until(rb"\x1b\[0m")
    # Each positioned run must end inside the new viewport.
    spans = re.split(rb"\x1b\[(\d+);(\d+)H", redraw)[1:]
    visible = []
    for row, column, run in zip(spans[::3], spans[1::3], spans[2::3]):
        label = re.sub(rb"\x1b\[[0-9;]*m", b"", run).decode()
        assert 1 <= int(row) <= rows and 1 <= int(column) <= cols - len(label) + 1, (row, column, label)
        visible.append(label)
    page = "\n".join(visible)
    for label in ("FPS", "▀", "AMMO 49", "Esc"):
        assert label in page, f"{label!r} missing at {cols}x{rows}"
    assert not re.search(r"SQL FPS|E1M1|GAME \d+", page), page


def run():
    with psycopg.connect(autocommit=True) as db:
        last_id = db.execute("SELECT COALESCE(max(id), 0) FROM doom.games").fetchone()[0]
        with db.transaction(), client() as (tty, proc):
            db.execute("LOCK TABLE doom.levels IN ACCESS EXCLUSIVE MODE")
            tty.until(b"New game")
            tty.until(b"< E1M7 >")
            tty.send(b"\r")
            tty.until(b"Loading E1M7")
            tty.until(b"1s    Q quit")
            tty.quit(proc)

        with client("--map", "e1m1") as (tty, proc):
            tty.until(b"MAIN MENU")
            tty.until(b"New game")
            tty.send(b"\x1b[B\x1b[C")
            tty.until(b"< E1M2 >")
            tty.send(b"\x1b[D\x1b[B\x1b[D")
            tty.until(b"Hey, not too rough")
            tty.send(b"\x1b[A\x1b[A\r")
            tty.until(b"Loading E1M1")
            tty.until(b"AMMO 50")
            tty.send(b" ")
            tty.until(b"AMMO 49")
            [(game, name, ammo, cooldown, skill)] = db.execute(
                """SELECT g.id, l.name, g.ammo, g.next_shot, g.difficulty
                   FROM doom.games g JOIN doom.levels l ON g.level=l.id WHERE g.id>%s""",
                (last_id,),
            ).fetchall()
            assert (name, ammo, skill) == ("E1M1", 49, 2) and cooldown > 0

            tty.send(b"\x1b")
            tty.until(b"PAUSED")
            tty.until(b"Resume")

            # A command can still be in flight when the menu opens.
            def tic():
                return db.execute("SELECT tic FROM doom.games WHERE id=%s", (game,)).fetchone()[0]

            end = time.monotonic() + 2
            while True:
                paused = tic()
                time.sleep(0.15)
                if tic() == paused:
                    break
                assert time.monotonic() < end, "game continued ticking behind the pause menu"
            tty.send(b"\r")
            tty.until(b"AMMO 49")
            resize_game(tty, 20, 60)
            end = time.monotonic() + 2
            while tic() <= paused:
                assert time.monotonic() < end, "resume did not restart SQL tics"
                time.sleep(0.02)
            # Q must restore the terminal even when the next tic is blocked in SQL.
            with db.transaction():
                db.execute("SELECT id FROM doom.games WHERE id=%s FOR UPDATE", (game,))
                time.sleep(0.1)
                tty.quit(proc)

        with client() as (tty, proc):
            tty.until(b"MAIN MENU")
            tty.send(b"\x1b[B" * 3 + b"\r")
            tty.until(b"LOAD GAME")
            saves = tty.until(f"#{game}   E1M1   Skill 2".encode())
            preceding = len(re.findall(rb"#\d+   ", saves)) - 1
            tty.send(b"\x1b[B" * preceding + b"\r")
            tty.until(f"Loading game #{game}".encode())
            tty.until(b"AMMO 49")

            # Give this player inventory and activate the Hangar's normal exit switch.
            with db.transaction():
                db.execute("UPDATE doom.games SET armor=25,keys=1 WHERE id=%s", (game,))
                db.execute("UPDATE doom.actors SET health=87 WHERE game=%s AND id=-1", (game,))
                db.execute(
                    """SELECT doom.activate(g,l.id,'use') FROM doom.games g
                              JOIN doom.lines l ON l.level=g.level AND l.special=11 WHERE g.id=%s""",
                    (game,),
                )
            tty.until(b"LEVEL COMPLETE")
            tty.until(b"Next map")
            tty.send(b"\r")
            tty.until(b"Loading E1M2")
            tty.until(b"HP 87%   ARM 25%   AMMO 49")
            advanced = db.execute(
                """SELECT l.name, g.keys FROM doom.games g
                   JOIN doom.levels l ON g.level=l.id WHERE g.id>%s""",
                (game,),
            ).fetchall()
            assert advanced == [("E1M2", 0)], advanced
            tty.quit(proc)
    print("Terminal new game, fire, pause, resize, load and next map passed")


if __name__ == "__main__":
    run()
