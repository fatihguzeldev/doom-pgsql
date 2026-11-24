import asyncio
import os
import shutil
import subprocess
import sys
from contextlib import ExitStack, asynccontextmanager, suppress
from pathlib import Path
from tempfile import TemporaryDirectory

_DOOM2_TRACKS = [
    "RUNNIN", "STALKS", "COUNTD", "BETWEE", "DOOM", "THE_DA", "SHAWN", "DDTBLU",
    "IN_CIT", "DEAD", "STLKS2", "THEDA2", "DOOM2", "DDTBL2", "RUNNI2", "DEAD2",
    "STLKS3", "ROMERO", "SHAWN2", "MESSAG", "COUNT2", "DDTBL3", "AMPIE", "THEDA3",
    "ADRIAN", "MESSG2", "ROMER2", "TENSE", "SHAWN3", "OPENIN", "EVIL", "ULTIMA",
]
_EPISODE4_TRACKS = ["E3M4", "E3M2", "E3M3", "E1M5", "E2M7", "E2M4", "E2M6", "E2M5", "E1M9"]
_MONSTER_SOUNDS = {
    3004: {"sight": "DSPOSIT1", "attack": "DSPISTOL", "pain": "DSPOPAIN", "death": "DSPODTH1"},
    9:    {"sight": "DSPOSIT2", "attack": "DSSHOTGN", "pain": "DSPOPAIN", "death": "DSPODTH2"},
    3001: {"sight": "DSBGSIT1", "attack": "DSCLAW",   "pain": "DSPOPAIN", "death": "DSBGDTH1"},
    3002: {"sight": "DSSGTSIT", "attack": "DSSGTATK", "pain": "DSDMPAIN", "death": "DSSGTDTH"},
    3003: {"sight": "DSBRSSIT", "attack": "DSFIRSHT", "pain": "DSDMPAIN", "death": "DSBRSDTH"},
    3005: {"sight": "DSCACSIT", "attack": "DSFIRSHT", "pain": "DSDMPAIN", "death": "DSCACDTH"},
    3006: {                     "attack": "DSSKLATK", "pain": "DSDMPAIN", "death": "DSFIRXPL"},
}
_MONSTER_SOUNDS[58] = _MONSTER_SOUNDS[3002]  # spectres use demon sounds


def map_track(name, music):
    track = "D_" + name
    if track in music:
        return track
    if len(name) == 4 and name.startswith("E4M") and name[3] in "123456789":
        return "D_" + _EPISODE4_TRACKS[int(name[3]) - 1]
    if name.startswith("MAP") and len(name) == 5 and name[3:].isascii() and name[3:].isdigit():
        number = int(name[3:])
        if 1 <= number <= len(_DOOM2_TRACKS):
            return "D_" + _DOOM2_TRACKS[number - 1]
    return None


class Audio:
    def __init__(self, art, directory, events, muted):
        self.art = art
        self.directory = directory
        self.events = events
        self.muted = muted
        self.renderer = None
        self.pending = None

    def _send(self, command):
        if self.events is not None:
            print(command, file=self.events, flush=True)

    def effect(self, name):
        if self.muted:
            return
        if self.events is None:
            if name == "DSPISTOL":
                sys.stdout.write("\a")
                sys.stdout.flush()
            return
        wav = self.art.sounds.get(name)
        if wav:
            path = self.directory / (name + ".wav")
            if not path.exists():
                path.write_bytes(wav)
            self._send("effect " + name)

    def monster(self, thing, event):
        name = _MONSTER_SOUNDS.get(thing, {}).get(event)
        if name:
            self.effect(name)

    async def music(self, name):
        if self.events is None:
            return
        if self.renderer is not None:
            if not self.pending.done():
                self.pending.cancel()
                if self.renderer.returncode is None:
                    with suppress(ProcessLookupError):
                        self.renderer.terminate()
                await self.renderer.wait()
            with suppress(asyncio.CancelledError):
                await self.pending
            self.renderer = self.pending = None
        self._send("stop")
        if name not in self.art.music:
            return
        path = self.directory / (name + ".wav")
        if path.exists():
            self._send("music " + name)
            return
        synth = shutil.which("wildmidi")
        if synth is None:
            return
        score = path.with_suffix(".mus")
        score.write_bytes(self.art.music[name])
        output = path.with_suffix(".part")
        output.unlink(missing_ok=True)
        self.renderer = await asyncio.create_subprocess_exec(
            synth, "-f", "140", "-r", "32000", "-m", "70", "-o", str(output), str(score),
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        self.pending = asyncio.create_task(self._finish_track(self.renderer, output, path, name))

    async def _finish_track(self, renderer, output, path, name):
        if await renderer.wait() == 0 and output.is_file() and output.stat().st_size > 44:
            output.replace(path)
            self._send("music " + name)
        else:
            output.unlink(missing_ok=True)


@asynccontextmanager
async def game_audio(art, muted):
    with ExitStack() as stack:
        directory = events = worker = None
        bridge = os.environ.get("DOOM_AUDIO_DIR")
        if not muted:
            if bridge:
                directory = Path(bridge)
            else:
                player = next((p for p in ("afplay", "paplay", "aplay") if shutil.which(p)), None)
                if player:
                    directory = Path(stack.enter_context(TemporaryDirectory()))
            if directory is not None:
                events = stack.enter_context((directory / "events").open("a"))
                if not bridge:
                    worker = await asyncio.create_subprocess_exec(
                        "bash", Path(__file__).with_name("audio.sh"), directory, player
                    )
        audio = Audio(art, directory, events, muted)
        try:
            yield audio
        finally:
            await audio.music(None)
            audio._send("quit")
            if worker is not None:
                await worker.wait()
