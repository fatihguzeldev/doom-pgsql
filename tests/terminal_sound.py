import asyncio
import os
import shutil
import tempfile
import unittest
import wave
from pathlib import Path
from unittest.mock import patch

from client.art import Art
from client.sound import game_audio, map_track

ROOT = Path(__file__).resolve().parents[1]


class AudioTest(unittest.IsolatedAsyncioTestCase):
    def test_map_music(self):
        self.assertEqual(map_track("E1M7", {"D_E1M7"}), "D_E1M7")
        self.assertEqual(map_track("MAP01", set()), "D_RUNNIN")
        self.assertEqual(map_track("E4M1", set()), "D_E3M4")
        self.assertIsNone(map_track("MAP00", set()))

    async def test_mute_writes_no_events(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"DOOM_AUDIO_DIR": directory}):
            async with game_audio(None, True) as audio:
                await audio.music("D_INTRO")
                audio.effect("DSPISTOL")
            self.assertEqual(list(Path(directory).iterdir()), [])

    @unittest.skipUnless(shutil.which("wildmidi"), "requires the music renderer")
    async def test_wad_music_and_effects_share_the_bridge(self):
        art = Art.from_bytes((ROOT / "assets/doom1.wad").read_bytes())
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"DOOM_AUDIO_DIR": directory}):
            path = Path(directory)
            async with game_audio(art, False) as audio:
                for track in ("D_INTRO", "D_E1M7"):
                    await audio.music(track)
                    await asyncio.wait_for(audio.pending, 20)
                    with wave.open(str(path / (track + ".wav"))) as wav:
                        self.assertGreater(wav.getnframes(), wav.getframerate())
                        self.assertGreater(len(set(wav.readframes(wav.getframerate() * 3))), 16)
                audio.effect("DSPISTOL")
                audio.monster(3001, "sight")
                audio.monster(3001, "attack")
                audio.monster(3001, "death")
                await audio.music("D_INTRO")
            cues = (path / "events").read_text().splitlines()
            self.assertEqual(cues, [
                "stop", "music D_INTRO", "stop", "music D_E1M7", "effect DSPISTOL",
                "effect DSBGSIT1", "effect DSCLAW", "effect DSBGDTH1",
                "stop", "music D_INTRO", "stop", "quit",
            ])
            self.assertTrue((path / "DSPISTOL.wav").is_file())
