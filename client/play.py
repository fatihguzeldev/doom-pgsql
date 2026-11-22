import argparse
import base64
import math
import os
import shutil
import sys
import termios
import tty
from contextlib import contextmanager
from pathlib import Path
from select import select
from time import monotonic

from client.frame import HEIGHT, WIDTH
from client.pg import Connection, integer
from client.session import FRAME, GAME, TICK, run


@contextmanager
def terminal():
    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd)
    tty.setcbreak(fd)
    sys.stdout.write('\x1b[?1049h\x1b[?25l')
    sys.stdout.flush()
    try:
        yield
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)
        sys.stdout.write('\x1b[0m\x1b[?25h\x1b[?1049l')
        sys.stdout.flush()


class Keyboard:
    def __init__(self):
        self.held = {}
        self.buffer = b''

    def __call__(self, tic):
        fd = sys.stdin.fileno()
        while select([fd], [], [], 0)[0]:
            chunk = os.read(fd, 128)
            if not chunk:
                raise KeyboardInterrupt
            self.buffer += chunk
        now = monotonic()
        use = fire = False
        while self.buffer:
            if self.buffer.startswith(b'\x1b'):
                if len(self.buffer) < 3:
                    break
                key = {'A': 'w', 'B': 's', 'C': 'l', 'D': 'j'}.get(chr(self.buffer[2]))
                self.buffer = self.buffer[3:]
            else:
                key, self.buffer = chr(self.buffer[0]).lower(), self.buffer[1:]
            if key == 'q':
                raise KeyboardInterrupt
            if key == 'e':
                use = True
            elif key == ' ':
                fire = True
            elif key in ('w', 'a', 's', 'd', 'j', 'l'):
                self.held[key] = now + 0.13

        def axis(positive, negative):
            return int(self.held.get(positive, 0) > now) - int(self.held.get(negative, 0) > now)

        return axis('w', 's'), axis('d', 'a'), 0.11 * axis('j', 'l'), use, fire


class Display:
    def __init__(self, connection, game):
        self.connection = connection
        self.game = game
        self.palettes = {}
        self.load(0)

    def load(self, palette_id):
        binary, = self.connection.execute(b'SELECT doom.frame_palette($1, $2)', self.game, palette_id)
        if not binary or len(binary) % (3 * 256):
            raise ValueError('invalid display palette')
        colors = [tuple(binary[i:i + 3]) for i in range(0, len(binary), 3)]
        self.palettes[palette_id] = colors
        return colors

    def __call__(self, snapshot, slot, palette_id, pixels, size, due, ready):
        palette = self.palettes.get(palette_id) or self.load(palette_id)
        columns, rows = shutil.get_terminal_size()
        w, h = max(1, min(WIDTH, columns - 1)), max(1, min(HEIGHT // 2, rows - 1))
        indices, shades = pixels
        output = ['\x1b[H']
        last_foreground = last_background = None
        for line in range(h):
            top = (line * HEIGHT // h) * WIDTH
            bottom = ((2 * line + 1) * HEIGHT // (2 * h)) * WIDTH
            for column in range(w):
                x = column * WIDTH // w
                a, b = top + x, bottom + x
                fore = palette[shades[a] * 256 + indices[a]]
                back = palette[shades[b] * 256 + indices[b]]
                if fore != last_foreground:
                    output.append(f'\x1b[38;2;{fore[0]};{fore[1]};{fore[2]}m')
                    last_foreground = fore
                if back != last_background:
                    output.append(f'\x1b[48;2;{back[0]};{back[1]};{back[2]}m')
                    last_background = back
                output.append('▀')
            output.append('\r\n')
        output.append('\x1b[0m\x1b[K')
        sys.stdout.write(''.join(output))
        sys.stdout.flush()


def main():
    parser = argparse.ArgumentParser(description='Play a PostgreSQL game in a truecolor terminal.')
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--wad', type=Path, help='load a local WAD with the server-side compiler')
    source.add_argument('--game', type=int, help='resume an existing database game ID')
    parser.add_argument('--map', default='E1M1')
    parser.add_argument('--skill', type=int, default=3, choices=range(1, 6))
    parser.add_argument('--in-flight', type=int, default=3)
    args = parser.parse_args()
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        parser.error('an interactive terminal is required')
    if args.in_flight < 1 or args.game is not None and args.game < 1:
        parser.error('game and pipeline limit must be positive')

    with Connection() as setup, Connection() as writer, Connection() as reader:
        game = args.game
        if args.wad:
            data = base64.b64encode(args.wad.read_bytes()).decode('ascii')
            level = integer(setup.execute(b"SELECT doom.load_wad(decode($1, 'base64'), $2)", data, args.map)[0])
            game = integer(setup.execute(b'SELECT doom.start($1, $2)', level, args.skill)[0])
        epoch, first_tic = map(integer, setup.execute(GAME, game))
        writer.execute(b"SET default_transaction_isolation TO 'repeatable read'")
        writer.prepare(TICK)
        reader.prepare(FRAME)
        for lane in (writer, reader):
            lane.start_pipeline()
        display = Display(setup, game)
        print(f'Game {game}. WASD to move, J/L or arrows to turn, E to use, Space to fire, Q to quit.', flush=True)
        try:
            with terminal():
                run(writer, reader, game, epoch, first_tic, Keyboard(), display, lambda *_: None,
                    in_flight=args.in_flight)
        except KeyboardInterrupt:
            pass


if __name__ == '__main__':
    main()
