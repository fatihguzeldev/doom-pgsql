from unittest import TestCase

from client.pg import Connection
from client.session import run


class SessionTest(TestCase):
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
            stats = run(writer, reader, 1, 5, 0, lambda _: (0, 0, 0, False, False),
                        lambda snapshot, slot, *rest: frames.append((snapshot, slot)),
                        lambda tic, *times: tics.append(tic), duration=0.2)
            self.assertEqual(tics, list(range(1, 8)))
            self.assertEqual(frames, [(i, i) for i in range(1, 7)])
            self.assertEqual(stats['skipped_frames'], 0)
            self.assertEqual(stats['tick_debt'], 0)
