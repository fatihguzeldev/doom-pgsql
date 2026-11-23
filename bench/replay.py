"""Measure native frames and acknowledged tics through PostgreSQL's public game API."""
import argparse
import hashlib
import json
import math
import statistics
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import psycopg
from psycopg.types.json import Jsonb


def route(n):
    if n<=32:
        return [1,0,0,n==13,n==26]
    if n<=68:
        return [0.6,0,0.035,False,n%13==0]
    heading = 1 if ((n-69)//64)%2==0 else -1
    return [0.6,0.25,0.035*heading,n%71==0,n%11==0]


def measure(dsn, game, seconds, rtt):
    barrier = threading.Barrier(3)
    delay = rtt/2000

    def inputs():
        timings, accepted = [], 0
        with psycopg.connect(dsn,autocommit=True) as writer:
            epoch,initial = writer.execute('SELECT epoch,tic FROM doom.game_status(%s)',(game,)).fetchone()
            barrier.wait()
            pending = 1
            while time.monotonic()<finish:
                now = time.monotonic()
                last = min(math.floor((now-start)*35)+1,pending+15)
                if pending>last:
                    time.sleep(max(0,start+(pending-1)/35-now))
                    continue
                batch = [route(n) for n in range(pending,last+1)]
                time.sleep(delay)
                writer.execute('CALL doom.submit(%s,%s,%s,%s)',(game,epoch,initial+pending,Jsonb(batch)))
                time.sleep(delay)
                if time.monotonic()<=finish:
                    accepted += len(batch)
                    timings.append(1000*(time.monotonic()-now))
                pending = last+1
        return accepted,timings

    def frames():
        timings, pictures, fresh, repeated, sent = [], set(), 0, 0, 0
        token = None
        with psycopg.connect(dsn,autocommit=True) as reader:
            epoch, = reader.execute('SELECT epoch FROM doom.game_status(%s)',(game,)).fetchone()
            barrier.wait()
            while time.monotonic()<finish:
                now = time.monotonic()
                sent += 1
                time.sleep(delay)
                pic,light,token = reader.execute('SELECT pixels,shades,token FROM doom.poll_frame(%s,%s,%s,%s)',
                    (game,epoch,sent,token),binary=True).fetchone()
                time.sleep(delay)
                if time.monotonic()<=finish:
                    timings.append(1000*(time.monotonic()-now))
                    if pic is None:
                        repeated+=1
                    else:
                        fresh+=1
                        pictures.add(hashlib.blake2s(pic+light).digest())
                time.sleep(max(0,1/30-(time.monotonic()-now)))
        return fresh,len(pictures),repeated,timings

    start = time.monotonic()+0.05
    finish = start+seconds
    with ThreadPoolExecutor(max_workers=2) as pool:
        writer,reader = pool.submit(inputs),pool.submit(frames)
        barrier.wait()
        tics,w = writer.result()
        fresh,distinct,reused,f = reader.result()
    return dict(seconds=seconds,artificial_rtt_ms=rtt,acknowledged_tics=tics,tics_per_s=tics/seconds,
        sql_frames=fresh,unique_images=distinct,unique_fps=distinct/seconds,reused=reused,
        median_frame_request_ms=statistics.median(f) if f else None,median_input_batch_ms=statistics.median(w) if w else None)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dsn',default='')
    which=parser.add_mutually_exclusive_group(required=True)
    which.add_argument('--wad',type=Path)
    which.add_argument('--level',type=int)
    parser.add_argument('--map',default='E1M3')
    parser.add_argument('--seconds',type=float,default=60)
    parser.add_argument('--rtt-ms',type=float,default=50,help='added delay split between each request and response')
    args=parser.parse_args()
    if args.seconds<=0 or args.rtt_ms<0:
        parser.error('duration must be positive and RTT nonnegative')
    with psycopg.connect(args.dsn,autocommit=True) as c:
        level=args.level or c.execute('SELECT doom.load_wad(%s,%s)',(args.wad.read_bytes(),args.map)).fetchone()[0]
        game=c.execute('SELECT game_id FROM doom.new_game(%s)',(level,)).fetchone()[0]
    print(json.dumps(measure(args.dsn,game,args.seconds,args.rtt_ms),indent=2))


if __name__=='__main__':
    main()
