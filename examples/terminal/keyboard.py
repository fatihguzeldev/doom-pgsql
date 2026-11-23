import asyncio
import os
import re
import sys
import termios
import tty
from collections import Counter
from contextlib import contextmanager

ARROWS = {"A": "up", "B": "down", "C": "right", "D": "left"}
MENU = {"w": "up", "s": "down", "a": "left", "d": "right"}
OPPOSITE = {
    "w": ("s", "down"),
    "up": ("s", "down"),
    "s": ("w", "up"),
    "down": ("w", "up"),
    "a": ("d",),
    "d": ("a",),
    "j": ("l", "right"),
    "left": ("l", "right"),
    "l": ("j", "left"),
    "right": ("j", "left"),
}
GAME_KEYS = {"w", "s", "a", "d", "j", "l", "e", " ", "r", *ARROWS.values()}
CONTROL_KEYS = GAME_KEYS | {"enter", "esc", "q"}
SEQUENCE = re.compile(rb"\x1b(?:\[([0-?]*)([ -/]*)|O)([@-~])")
ESC_DELAY = 0.05
# Without key-up, a first tap can move until the OS's initial repeat delay expires.
FIRST_REPEAT_LEASE = 0.55
REPEAT_LEASE = 0.14
TAP_HIGHLIGHT = 0.10


class Keyboard:
    def __init__(self):
        self.quit = asyncio.Event()
        self.menu_keys = asyncio.Queue()
        self.in_menu = False
        self.auto_walk = False
        self.reports_release = False
        self._down = set()
        self._until = {}
        self._taps = set()
        self._actions = Counter()
        self._lights = {}
        self._buffer = b""
        self._escape_timer = None

    def _clear_keys(self):
        self._down.clear()
        self._until.clear()
        self._taps.clear()
        self._actions.clear()
        self._lights.clear()
        self.auto_walk = False

    def lit_keys(self, now):
        """Return physical controls held or briefly lit after a tap."""
        return frozenset(key for key, (held, until) in self._lights.items() if held or now < until)

    def _active(self, now):
        return self._down | self._taps | {k for k, expiry in self._until.items() if now < expiry}

    @staticmethod
    def _turn(active):
        left = "j" in active or "left" in active
        right = "l" in active or "right" in active
        return 0.09 * (left - right)

    def pending_turn(self, now):
        # Preview a fresh press even while SQL is preventing the next input sample.
        if self._taps.isdisjoint(("j", "left", "l", "right")):
            return 0.0
        return self._turn(self._active(now))

    def set_menu(self, enabled):
        self.in_menu = enabled
        self._clear_keys()
        while not self.menu_keys.empty():
            self.menu_keys.get_nowait()

    def _quit(self):
        self.quit.set()
        if self.in_menu:
            self.menu_keys.put_nowait("q")

    def _key(self, key, event, now, reports_release):
        if event == 3:
            self._down.discard(key)
            self._until.pop(key, None)
            if key in self._lights:
                _, until = self._lights[key]
                self._lights[key] = False, until
            return
        if event == 1 and key in CONTROL_KEYS:
            duration = TAP_HIGHLIGHT if reports_release else REPEAT_LEASE
            self._lights[key] = reports_release, now + duration
        if key == "q":
            self._quit()
            return
        if self.in_menu:
            action = MENU.get(key, key)
            if action in ARROWS.values() or (event == 1 and action in ("enter", "esc")):
                self.menu_keys.put_nowait(action)
            return
        if key == "esc":
            if event == 1:
                self.menu_keys.put_nowait("esc")
            return
        if key not in GAME_KEYS:
            return
        if reports_release:
            if event == 2 or key in self._down:
                return
            self._down.add(key)
        else:
            repeating = now < self._until.get(key, 0)
            bridge_first_repeat = not repeating and (key in OPPOSITE or key == "r")
            self._until[key] = now + (FIRST_REPEAT_LEASE if bridge_first_repeat else REPEAT_LEASE)
            for opposite in OPPOSITE.get(key, ()):
                self._until.pop(opposite, None)
                self._taps.discard(opposite)
            if key == "r" and repeating:
                return
        if key == "r":
            self.auto_walk = not self.auto_walk
        elif key in ("e", " "):
            self._actions[key] += 1
        else:
            self._taps.add(key)

    def _control(self, params, final, now):
        if not params and final in ("I", "O"):
            if final == "O":
                self._clear_keys()
            return
        if final == "u" and params.startswith("?"):
            flags = params[1:]
            if flags.isdecimal():
                self.reports_release = int(flags) & 10 == 10
            return
        if (final not in ARROWS and final != "u") or not re.fullmatch(r"[0-9:;]*", params):
            return
        fields = params.split(";")
        modifiers = fields[1].split(":") if len(fields) > 1 else [""]
        event = int(modifiers[1] or 1) if len(modifiers) > 1 else 1
        if event not in (1, 2, 3):
            return
        if final == "u":
            code = fields[0].split(":")[0]
            if not code or int(code) > 127:
                return
            key = chr(int(code)).lower()
            if key == "c" and (int(modifiers[0] or 1) - 1) & 4:
                if event == 1:
                    self._quit()
                return
            key = {"\x1b": "esc", "\r": "enter"}.get(key, key)
        else:
            key = ARROWS[final]
        encoded = self.reports_release or final == "u" or len(modifiers) > 1
        self._key(key, event, now, encoded)

    def _cancel_escape(self):
        if self._escape_timer:
            self._escape_timer.cancel()
            self._escape_timer = None

    def _escape(self):
        self._escape_timer = None
        self._buffer = b""
        self._key("esc", 1, asyncio.get_running_loop().time(), False)

    def feed(self, data, now):
        self._cancel_escape()
        self._buffer += data
        while self._buffer:
            if self._buffer[:1] != b"\x1b":
                char = chr(self._buffer[0]).lower()
                self._buffer = self._buffer[1:]
                if char == "\x03":
                    self._quit()
                else:
                    self._key("enter" if char in "\r\n" else char, 1, now, False)
                continue
            if len(self._buffer) == 1:
                self._escape_timer = asyncio.get_running_loop().call_later(ESC_DELAY, self._escape)
                return
            if self._buffer[1:2] in (b"[", b"O"):
                match = SEQUENCE.match(self._buffer)
                if not match:
                    if len(self._buffer) < 128 and b"\x1b" not in self._buffer[2:]:
                        return
                    self._buffer = self._buffer[2:]
                    continue
                params, extra, final = match.groups()
                self._buffer = self._buffer[match.end() :]
                if params is None:
                    self._key(ARROWS.get(final.decode("ascii"), ""), 1, now, False)
                elif not extra and len(params) < 96:
                    self._control(params.decode("ascii"), final.decode("ascii"), now)
                continue
            self._buffer = self._buffer[1:]
            self._key("esc", 1, now, False)

    def receive(self):
        chunk = os.read(sys.stdin.fileno(), 256)
        if chunk:
            self.feed(chunk, asyncio.get_running_loop().time())
        else:
            self._quit()

    def sample(self, now):
        active = self._active(now)
        back = "s" in active or "down" in active
        forward = "w" in active or "up" in active or (self.auto_walk and not back)
        turn = self._turn(active)
        use = self._actions["e"] > 0
        fire = self._actions[" "] > 0 or " " in active
        self._taps.clear()
        for key in ("e", " "):
            if self._actions[key]:
                self._actions[key] -= 1
        return forward - back, ("a" in active) - ("d" in active), turn, use, fire


@contextmanager
def screen(keyboard):
    fd = sys.stdin.fileno()
    settings = termios.tcgetattr(fd)
    loop = asyncio.get_running_loop()
    try:
        tty.setcbreak(fd)
        loop.add_reader(fd, keyboard.receive)
        sys.stdout.write("\x1b[?1049h\x1b[?25l\x1b[?1004h\x1b[>11u\x1b[?u")
        sys.stdout.flush()
        yield
    finally:
        keyboard._cancel_escape()
        loop.remove_reader(fd)
        termios.tcsetattr(fd, termios.TCSADRAIN, settings)
        sys.stdout.write("\x1b[<u\x1b[?1004l\x1b[0m\x1b[?25h\x1b[?1049l")
        sys.stdout.flush()
