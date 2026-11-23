import asyncio
import unittest
from contextlib import suppress
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

import psycopg

from examples.terminal.session import Session


class SessionTest(unittest.IsolatedAsyncioTestCase):
    async def test_retry_keeps_unacknowledged_batch_separate_from_new_input(self):
        args = SimpleNamespace(dsn="", rtt_ms=0, delta=False, predict_turn=False)
        state = dict(game=1, epoch=1, tic=40, next_shot=0)
        session = Session(args, state, None)
        forward = [1, 0, 0, False, False]
        fire = [0, 0, 0, False, True]
        session.pending.put_nowait(forward)
        attempts = []
        fire_sent = asyncio.Event()

        async def query(db, delay, sql, params):
            _, _, tic, commands = params
            attempts.append((tic, list(commands.obj)))
            if len(attempts) == 1:
                session.pending.put_nowait(fire)
                raise psycopg.OperationalError("lost reply")
            if fire in commands.obj:
                fire_sent.set()

        with patch("examples.terminal.session.connect", new_callable=AsyncMock), patch(
            "examples.terminal.session.game_query", query
        ):
            worker = asyncio.create_task(session.submit())
            try:
                await asyncio.wait_for(fire_sent.wait(), timeout=2)
            finally:
                worker.cancel()
                with suppress(asyncio.CancelledError):
                    await worker
        self.assertEqual(attempts, [(41, [forward]), (41, [forward]), (42, [fire])])
