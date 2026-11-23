"""Check committed prefixes and retries after loss of an actual PostgreSQL session."""

import argparse
import time
from concurrent.futures import ThreadPoolExecutor

import psycopg
from psycopg.types.json import Jsonb


def verify(level):
    with psycopg.connect(autocommit=True) as observer, psycopg.connect(autocommit=True) as writer:
        victim = writer.info.backend_pid
        games = [
            observer.execute("SELECT game_id FROM doom.new_game(%s)", (level,)).fetchone()[0]
            for _ in range(2)
        ]
        commands = [[0, 0, 0.02, False, False] for _ in range(1024)]
        args = (games[0], 1, 1, Jsonb(commands))
        sql = "CALL doom.submit(%s,%s,%s,%s)"
        with ThreadPoolExecutor(max_workers=1) as pool:
            request = pool.submit(writer.execute, sql, args)
            while True:
                (seen,) = observer.execute("SELECT tic FROM doom.game_status(%s)", (games[0],)).fetchone()
                if 0 < seen < len(commands):
                    break
                if request.done():
                    raise AssertionError("did not observe a committed batch prefix")
                time.sleep(0.001)
            assert observer.execute("SELECT pg_terminate_backend(%s)", (victim,)).fetchone()[0]
            try:
                request.result()
            except psycopg.OperationalError:
                pass
            else:
                raise AssertionError("writer did not lose its connection")
        for game in games:
            (ack,) = observer.execute(sql, (game, 1, 1, Jsonb(commands))).fetchone()
            assert ack == len(commands)
        states = observer.execute(
            "SELECT pos::text,yaw,z,health FROM doom.actors WHERE id=-1 AND game=ANY(%s) ORDER BY game",
            (games,),
        ).fetchall()
        assert len(states) == 2 and states[0] == states[1]
        print(
            f"observed committed prefix at tic {seen}; recovered and uninterrupted games match at tic {len(commands)}"
        )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("level", type=int)
    verify(parser.parse_args().level)
