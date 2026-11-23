import os
import unittest
from unittest.mock import patch

from examples.terminal.play import local_rtt_ms


class LocalSettingsTest(unittest.TestCase):
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
