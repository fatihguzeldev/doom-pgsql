"""Run with python -m examples.terminal.play --wad doom1.wad --map E1M3."""
import argparse
import asyncio
import math
import os
import shutil
import sys
import termios
import tty
from contextlib import contextmanager
from pathlib import Path

import psycopg
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb


class Keyboard:
    def __init__(self):
        self.until = {}
        self.pressed = set()
        self.buffer = b''
        self.quit = asyncio.Event()

    def receive(self):
        chunk = os.read(sys.stdin.fileno(), 256)
        if not chunk:
            self.quit.set()
            return
        self.buffer += chunk
        now = asyncio.get_running_loop().time()
        while self.buffer:
            if self.buffer.startswith(b'\x1b') and len(self.buffer) < 3:
                return
            if self.buffer.startswith(b'\x1b['):
                key = {65: 'w', 66: 's', 67: 'l', 68: 'j'}.get(self.buffer[2])
                self.buffer = self.buffer[3:]
            else:
                key = chr(self.buffer[0]).lower()
                self.buffer = self.buffer[1:]
            if key == 'q':
                self.quit.set()
            elif key in ('e', ' '):
                self.pressed.add(key)
            elif key in ('w', 's', 'a', 'd', 'j', 'l'):
                self.until[key] = now + 0.14

    def sample(self, now):
        def held(key):
            return self.until.get(key, 0) > now
        command = (held('w') - held('s'), held('a') - held('d'),
                   0.09 * (held('j') - held('l')), 'e' in self.pressed, ' ' in self.pressed)
        self.pressed.clear()
        return command


@contextmanager
def screen(keyboard):
    fd = sys.stdin.fileno()
    settings = termios.tcgetattr(fd)
    loop = asyncio.get_running_loop()
    try:
        tty.setcbreak(fd)
        loop.add_reader(fd, keyboard.receive)
        sys.stdout.write('\x1b[?1049h\x1b[?25l')
        yield
    finally:
        loop.remove_reader(fd)
        termios.tcsetattr(fd, termios.TCSADRAIN, settings)
        sys.stdout.write('\x1b[0m\x1b[?25h\x1b[?1049l')
        sys.stdout.flush()


class Display:
    def __init__(self):
        self.frame = None
        self.palette = None

    def paint(self, turn=0):
        frame = self.frame
        w, h = frame['width'], frame['height']
        cols, lines = shutil.get_terminal_size()
        cols, lines = max(1, cols-1), max(1, lines-1)
        # A terminal cell contains two square samples. Fit with that aspect ratio.
        scale = min(cols/w, 2*lines/h)
        cols, lines = max(1, int(scale*w)), max(1, int(scale*h/2))
        cos, sin = math.cos(turn), math.sin(turn)
        source = []
        for x in range(cols):
            ray = 2*(x+0.5)/cols-1
            depth = cos+ray*sin
            u = math.floor(w*(1+(ray*cos-sin)/depth)/2) if depth>0 else -1
            source.append((u, depth))
        pixels, shades = frame['pixels'], frame['shades']
        palette = self.palette
        output = ['\x1b[H']
        fg = bg = None
        for row in range(lines):
            for u, depth in source:
                rgb = []
                for half in (0, 1):
                    v = math.floor(h/2 + ((row+(half+0.5)/2)/lines-0.5)*h/depth) if depth>0 else -1
                    if 0<=u<w and 0<=v<h:
                        i = u*h+v
                        rgb.append(palette[256*shades[i]+pixels[i]])
                    else:
                        rgb.append('0;0;0')
                if fg != rgb[0]:
                    fg = rgb[0]
                    output.append(f'\x1b[38;2;{fg}m')
                if bg != rgb[1]:
                    bg = rgb[1]
                    output.append(f'\x1b[48;2;{bg}m')
                output.append('▀')
            if row+1 < lines:
                output.append('\r\n')
        sys.stdout.write(''.join(output))
        sys.stdout.flush()


async def play(args):
    async def connect():
        return await psycopg.AsyncConnection.connect(args.dsn, autocommit=True, row_factory=dict_row)
    async with await connect() as setup:
        if args.wad:
            result = await setup.execute('SELECT doom.load_wad(%s,%s) AS id', (args.wad.read_bytes(),args.map))
            level = (await result.fetchone())['id']
            result = await setup.execute('SELECT * FROM doom.new_game(%s,%s)', (level,args.skill))
        else:
            result = await setup.execute('SELECT * FROM doom.game_status(%s)', (args.game,))
        state = await result.fetchone()
        if not state:
            raise ValueError('game does not exist')
    game, epoch, initial = state['game_id'], state['epoch'], state['tic']
    keys, display = Keyboard(), Display()
    pending = asyncio.Queue()
    turns = {}
    clock = asyncio.get_running_loop().time

    async def capture():
        deadline = clock()
        tick = initial
        while True:
            await asyncio.sleep(max(0,deadline-clock()))
            tick += 1
            cmd = keys.sample(clock())
            if cmd[2]:
                turns[tick] = cmd[2]
            pending.put_nowait((tick,cmd))
            if args.predict_turn and cmd[2] and display.frame:
                display.paint(sum(turns.values()))
            deadline += 1/35

    async def send():
        batch = []
        while True:
            try:
                async with await connect() as conn:
                    while True:
                        if not batch:
                            batch.append(await pending.get())
                        while not pending.empty() and len(batch)<16:
                            batch.append(pending.get_nowait())
                        await conn.execute('CALL doom.submit(%s,%s,%s,%s)',
                                           (game,epoch,batch[0][0],Jsonb([v for _,v in batch])))
                        batch.clear()
            except (psycopg.OperationalError, psycopg.errors.SerializationFailure, psycopg.errors.DeadlockDetected):
                await asyncio.sleep(0.1)

    async def receive():
        token, revision, slot = None, None, 0
        hashes = None
        while True:
            try:
                async with await connect() as conn:
                    while True:
                        begin = clock()
                        slot += 1
                        if args.delta:
                            result = await conn.execute('SELECT * FROM doom.poll_tiles(%s,%s,%s,%s,%s)',
                                                        (game,epoch,slot,token,hashes), binary=True)
                        else:
                            result = await conn.execute('SELECT * FROM doom.poll_frame(%s,%s,%s,%s)',
                                                        (game,epoch,slot,token), binary=True)
                        frame = await result.fetchone()
                        if args.delta:
                            hashes = frame['hashes']
                            if frame['tiles']:
                                for channel in ('pixels','shades'):
                                    data = bytearray(display.frame[channel]) if display.frame else bytearray(frame['width']*frame['height'])
                                    for i,tile in enumerate(frame['tiles']):
                                        data[tile*800:(tile+1)*800] = frame[channel][i*800:(i+1)*800]
                                    frame[channel] = data
                            elif revision != frame['palette_revision'] and display.frame:
                                frame['pixels'],frame['shades'] = display.frame['pixels'],display.frame['shades']
                        if revision != frame['palette_revision']:
                            result = await conn.execute('SELECT doom.frame_palette(%s) AS rgb',(game,),binary=True)
                            data = (await result.fetchone())['rgb']
                            display.palette = [f'{r};{g};{b}' for r,g,b in zip(data[::3],data[1::3],data[2::3])]
                            revision = frame['palette_revision']
                        for tic in list(turns):
                            if tic<=frame['tic']:
                                del turns[tic]
                        if frame['pixels'] is not None:
                            display.frame = frame
                            display.paint(sum(turns.values()) if args.predict_turn else 0)
                        token = frame['token']
                        if frame['finished']:
                            keys.quit.set()
                            return
                        await asyncio.sleep(max(0,1/30-(clock()-begin)))
            except psycopg.OperationalError:
                await asyncio.sleep(0.1)

    print(f"Game {game} · WASD move · J/L turn · E use · Space fire · Q quit", flush=True)
    with screen(keys):
        tasks = [asyncio.create_task(fn()) for fn in (capture,send,receive,keys.quit.wait)]
        try:
            done,_ = await asyncio.wait(tasks,return_when=asyncio.FIRST_COMPLETED)
            for task in done:
                task.result()
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks,return_exceptions=True)


def main():
    parser = argparse.ArgumentParser(description='Play SQL Doom in a truecolor terminal. libpq PG* variables are supported.')
    parser.add_argument('--dsn', default='')
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--wad', type=Path)
    group.add_argument('--game', type=int)
    parser.add_argument('--map', default='E1M1')
    parser.add_argument('--skill',type=int,choices=range(1,6),default=3)
    parser.add_argument('--delta', action='store_true', help='receive changed eight-column strips')
    parser.add_argument('--predict-turn', action='store_true', help='reproject the last SQL frame during local turns')
    args = parser.parse_args()
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        parser.error('requires an interactive terminal')
    asyncio.run(play(args))


if __name__ == '__main__':
    main()
