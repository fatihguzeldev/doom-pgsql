from select import select
from time import monotonic
from unittest import TestCase

from client.pg import Connection, SqlError, integer


class PipelineTest(TestCase):
    def test_sync_commits_each_request_and_error_does_not_poison_next(self):
        with Connection() as connection:
            connection.execute(b'CREATE TEMP TABLE pipeline_test (id bigint PRIMARY KEY)')
            connection.prepare(b'INSERT INTO pipeline_test VALUES ($1) RETURNING id')
            connection.start_pipeline()
            for tag, value in enumerate((10, 10, 20)):
                connection.send(tag, value)
            results = []
            end = monotonic() + 3
            while connection.pending:
                remaining = end - monotonic()
                self.assertGreater(remaining, 0)
                readable, writable, _ = select([connection.fd], [connection.fd] if connection.wants_write else [], [], remaining)
                results += connection.poll(bool(readable), bool(writable))
            self.assertEqual([tag for tag, _ in results], [0, 1, 2])
            self.assertEqual(integer(results[0][1][0]), 10)
            self.assertIsInstance(results[1][1], SqlError)
            self.assertEqual(results[1][1].code, '23505')
            self.assertEqual(integer(results[2][1][0]), 20)
