import os
import unittest
from contextlib import redirect_stderr
from io import StringIO
from unittest.mock import patch

from client.play import local_rtt_ms, parse_args, render_resolution


class LocalSettingsTest(unittest.TestCase):
    @patch("sys.stdin.isatty", return_value=True)
    @patch("sys.stdout.isatty", return_value=True)
    def test_dsn_selection(self, *_):
        env = {"DOOM_LOCAL_DSN": "dbname=local", "DOOM_DSN": "dbname=saved", "DOOM_RTT_MS": "46"}
        with patch.dict(os.environ, env, clear=True):
            for flags, dsn, rtt in (
                ([], "dbname=local", 46),
                (["--dsn", "--rife"], "dbname=saved", 0),
                (["--dsn", "dbname=other"], "dbname=other", 0),
                (["--dsn=dbname=other"], "dbname=other", 0),
                (["--dsn", ""], "", 0),
            ):
                with self.subTest(flags=flags):
                    args = parse_args(flags)
                    self.assertEqual((args.dsn, args.rtt_ms), (dsn, rtt))

    def test_bare_dsn_requires_a_saved_address(self):
        with (
            patch.dict(os.environ, {}, clear=True),
            redirect_stderr(StringIO()) as message,
            self.assertRaises(SystemExit) as error,
        ):
            parse_args(["--dsn"])
        self.assertEqual(error.exception.code, 2)
        self.assertIn("set DOOM_DSN in .env", message.getvalue())

    def test_native_resolution_without_a_local_setting(self):
        with patch.dict(os.environ, {}, clear=True):
            for rife in (True, False):
                self.assertEqual(render_resolution(None, None, rife), (160, 100))
                self.assertEqual(render_resolution(None, "97x61", rife), (97, 61))

    def test_rife_resolution_flags_override_the_local_setting(self):
        with patch.dict(os.environ, {"DOOM_RIFE_RESOLUTION": "64x40"}):
            self.assertEqual(render_resolution(None, None, True), (64, 40))
            self.assertEqual(render_resolution(None, None, False), (160, 100))
            self.assertEqual(render_resolution(None, "96x60", True), (96, 60))

    def test_explicit_dsn_ignores_the_local_rife_resolution(self):
        with patch.dict(os.environ, {"DOOM_RIFE_RESOLUTION": "invalid"}):
            with self.assertRaises(ValueError):
                render_resolution(None, None, True)
            for dsn in ("", "dbname=mygame"):
                self.assertEqual(render_resolution(dsn, None, True), (160, 100))
                self.assertEqual(render_resolution(dsn, "128x80", True), (128, 80))

    def test_invalid_render_size(self):
        for value in ("-1x40", "64", "64x0", "640x7", "640x400junk", "4097x160"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                render_resolution(None, value, True)

    def test_local_rtt_override(self):
        with patch.dict(os.environ, {"DOOM_RTT_MS": "46"}):
            self.assertEqual(local_rtt_ms(None, None), 46)
            self.assertEqual(local_rtt_ms(None, "0"), 0)
        for value in ("-1", "nan", "inf", "invalid"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                local_rtt_ms(None, value)

    def test_explicit_dsn_ignores_local_latency(self):
        with patch.dict(os.environ, {"DOOM_RTT_MS": "invalid"}):
            for dsn in ("", "dbname=mygame"):
                self.assertEqual(local_rtt_ms(dsn, None), 0)
                self.assertEqual(local_rtt_ms(dsn, "80"), 0)
