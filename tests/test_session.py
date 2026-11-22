import unittest
from unittest.mock import patch

from client import session
from client.pg import Connection, SqlError


def integer(value):
    return value.to_bytes(8, 'big', signed=True)


class Clock:
    def __init__(self):
        self.time = 0
        self.first_wait = True

    def monotonic(self):
        return self.time

    def select(self, readers, writers, exceptions, timeout):
        if self.first_wait:
            self.first_wait = False
            # Let the open-loop writer get several calls in flight.
            self.time += 0.17
        else:
            self.time += max(0.001, min(timeout or 0.001, 0.03))
        return readers, writers, []


class Game:
    def __init__(self, end=None):
        self.tic = 0
        self.end = end
        self.applied = {}

    def step(self, tag, inputs):
        if tag == self.tic + 1 and (self.end is None or self.tic < self.end):
            self.tic = tag
            self.applied[tag] = inputs
        elif tag > self.tic + 1 and (self.end is None or self.tic < self.end):
            return SqlError('tic gap', session.TICK_GAP)
        return (integer(self.tic),)


class Lane:
    wants_write = False

    def __init__(self, sequence, result):
        self.fd = sequence
        self.result = result
        self.queue = []
        self.fail = False
        self.closed = False

    @property
    def pending(self):
        return len(self.queue)

    def send(self, tag, *args):
        self.queue.append((tag, self.result(tag, args)))

    def poll(self, _readable, _writable):
        if self.fail and self.queue:
            raise ConnectionError('lost socket after server produced results')
        ready, self.queue = self.queue, []
        return ready

    def close(self):
        self.closed = True


class SessionTest(unittest.TestCase):
    def setUp(self):
        clock = Clock()
        self.monotonic = patch.object(session, 'monotonic', clock.monotonic)
        self.select = patch.object(session, 'select', clock.select)
        self.decode = patch.object(session, 'unpack_frame', lambda payload: payload)
        for replacement in (self.monotonic, self.select, self.decode):
            replacement.start()
            self.addCleanup(replacement.stop)
        self.captured = []
        self.confirmed = []
        self.displayed = []

    def input_at(self, tag):
        self.captured.append(tag)
        return 0, 0, 0, False, tag == 2

    def play(self, writer, reader, **options):
        return session.run(writer, reader, 1, 1, 0, self.input_at,
                           lambda tic, *_: self.displayed.append(tic),
                           lambda tic, *_: self.confirmed.append(tic), **options)

    def lanes(self, game, step=None):
        writer = Lane(1, step or (lambda tag, args: game.step(tag, args[3:])))
        reader = Lane(2, lambda tag, _args: (integer(1), integer(game.tic), integer(tag), integer(0), b'frame'))
        return writer, reader

    def test_recovers_lost_commit_without_recapturing_or_reapplying_input(self):
        game = Game()
        writer, reader = self.lanes(game)
        writer.fail = True

        def reconnect():
            return self.lanes(game)

        stats = self.play(writer, reader, duration=0.3, reconnect=reconnect)
        self.assertTrue(writer.closed and reader.closed)
        self.assertEqual(stats['reconnects'], 1)
        self.assertEqual(self.captured, self.confirmed)
        self.assertEqual(list(game.applied), self.confirmed)
        self.assertEqual([tag for tag, inputs in game.applied.items() if inputs[-1]], [2])

    def test_connect_attempts_are_bounded(self):
        game = Game()
        writer, reader = self.lanes(game)
        writer.fail = True
        attempts = []

        def reconnect():
            attempts.append(True)
            raise ConnectionError('still disconnected')

        with self.assertRaises(ConnectionError):
            self.play(writer, reader, reconnect=reconnect)
        self.assertEqual(len(attempts), 2)

    def test_stops_and_displays_committed_terminal_frame(self):
        game = Game(end=3)
        stats = self.play(*self.lanes(game))
        self.assertEqual(self.confirmed, [1, 2, 3])
        self.assertEqual(self.displayed[-1], 3)
        self.assertEqual(stats['finished_at_tic'], 3)
        self.assertEqual(stats['tick_debt'], 0)

    def test_retries_gap_following_a_rolled_back_tic(self):
        game = Game()
        rolled_back = False

        def step(tag, args):
            nonlocal rolled_back
            if tag == 1 and not rolled_back:
                rolled_back = True
                return SqlError('serialization failed', '40001')
            return game.step(tag, args[3:])

        stats = self.play(*self.lanes(game, step), duration=0.3)
        self.assertEqual(self.captured, self.confirmed)
        self.assertEqual(stats['tick_debt'], 0)

    def test_does_not_treat_invalid_input_as_a_gap_after_rollback(self):
        game = Game()

        def step(tag, _args):
            return SqlError('invalid input', '22023') if tag == 2 else SqlError('serialization failed', '40001')

        with self.assertRaises(SqlError) as rejected:
            self.play(*self.lanes(game, step), duration=0.3)
        self.assertEqual(rejected.exception.code, '22023')


class SessionIntegrationTest(unittest.TestCase):
    def test_independent_read_and_commit_lanes_follow_requested_slots(self):
        with Connection() as writer, Connection() as reader:
            writer.execute(b'CREATE TEMP TABLE ticks (id bigint PRIMARY KEY)')
            writer.prepare(b'''INSERT INTO ticks SELECT $3::bigint WHERE $1::bigint = 1 AND $2::bigint = 5
                                AND $4::int + $5::int + $6::int = 0 AND NOT $7::boolean AND NOT $8::boolean
                                RETURNING id''')
            reader.prepare(b'''
                SELECT $2::bigint, $3::bigint, $3::bigint, 0, (
                    SELECT string_agg(int2send((y * 160)::smallint) || decode('a000', 'hex') ||
                                      decode(repeat('47', 160), 'hex'), ''::bytea ORDER BY y)
                    FROM generate_series(0, 99) AS y
                ) WHERE $1::bigint = 1
            ''')
            for connection in (writer, reader):
                connection.start_pipeline()
            tics, frames = [], []
            stats = session.run(writer, reader, 1, 5, 0, lambda _: (0, 0, 0, False, False),
                        lambda snapshot, slot, *rest: frames.append((snapshot, slot)),
                        lambda tic, *times: tics.append(tic), duration=0.2)
            self.assertEqual(tics, list(range(1, 8)))
            self.assertEqual(frames, [(i, i) for i in range(1, 7)])
            self.assertEqual(stats['skipped_frames'], 0)
            self.assertEqual(stats['tick_debt'], 0)

if __name__ == '__main__':
    unittest.main()
