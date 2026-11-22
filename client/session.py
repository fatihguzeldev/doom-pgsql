from math import ceil, floor
from select import select
from time import monotonic

from client.frame import unpack_frame
from client.pg import SqlError, integer


TIC_RATE = 35
FRAME_RATE = 30
TICK = b'SELECT doom.tick($1, $2, $3, $4, $5, $6, $7, $8)'
FRAME = b'SELECT * FROM doom.frame($1, $2, $3)'
GAME = b'SELECT epoch, tick_number FROM doom.games WHERE game_id = $1'


def run(writer, reader, game, epoch, first_tic, input_at, on_frame, on_tick,
        *, duration=None, in_flight=3, drain_timeout=3.0):
    if in_flight < 1 or (duration is not None and duration <= 0):
        raise ValueError('positive queue limit and duration required')
    start = monotonic() + 0.025
    end = float('inf') if duration is None else start + duration
    last_tic = None if duration is None else first_tic + round(duration * TIC_RATE)
    last_slot = None if duration is None else round(duration * FRAME_RATE)
    tic, acknowledged, slot, displayed = first_tic + 1, first_tic, 1, first_tic - 1
    commands = {}
    last_payload = last_palette = None
    retry = False
    skipped = stale = frames = 0

    def tick_time(number):
        return start + (number - first_tic - 1) / TIC_RATE

    def frame_time(number):
        return start + (number - 0.5) / FRAME_RATE

    while True:
        now = monotonic()
        active = now < end
        if retry and not writer.pending:
            tic = acknowledged + 1
            retry = False
        if active and not retry:
            while writer.pending < in_flight and (last_tic is None or tic <= last_tic) and now >= tick_time(tic):
                if tic not in commands:
                    commands[tic] = input_at(tic)
                writer.send(tic, game, epoch, tic, *commands[tic])
                tic += 1
        if active and now >= frame_time(slot) and (last_slot is None or slot <= last_slot):
            current = max(slot, floor((now - start) * FRAME_RATE + 0.5))
            if last_slot is not None:
                current = min(current, last_slot)
            skipped += current - slot
            slot = current + 1
            if reader.pending < in_flight:
                reader.send(current, game, epoch, current)
                frames += 1
            else:
                skipped += 1
        if not active and (not (reader.pending or writer.pending) or now >= end + drain_timeout):
            break

        lanes = (writer, reader)
        deadline = end if active else end + drain_timeout
        if active:
            if not retry and writer.pending < in_flight and (last_tic is None or tic <= last_tic):
                deadline = min(deadline, tick_time(tic))
            if last_slot is None or slot <= last_slot:
                deadline = min(deadline, frame_time(slot))
        readable, writable, _ = select([lane.fd for lane in lanes], [lane.fd for lane in lanes if lane.wants_write],
                                       [], None if deadline == float('inf') else max(0, deadline - monotonic()))
        for tag, result in writer.poll(writer.fd in readable, writer.fd in writable):
            if isinstance(result, SqlError):
                if result.code in ('40001', '40P01') or (retry and result.code == '22023'):
                    retry = True
                    continue
                raise result
            accepted = integer(result[0])
            if accepted < tag:
                raise ValueError('tick did not reach its requested sequence')
            while acknowledged < tag:
                acknowledged += 1
                commands.pop(acknowledged, None)
                on_tick(acknowledged, tick_time(acknowledged), monotonic())
        for tag, result in reader.poll(reader.fd in readable, reader.fd in writable):
            if isinstance(result, SqlError):
                raise result
            response_epoch, snapshot, response_slot, palette = map(integer, result[:4])
            if response_epoch != epoch or response_slot != tag:
                raise ValueError('frame belongs to another generation or slot')
            if snapshot < displayed or (snapshot == displayed and result[4] == last_payload and palette == last_palette):
                stale += 1
                continue
            pixels = unpack_frame(result[4])
            displayed, last_payload, last_palette = snapshot, result[4], palette
            on_frame(snapshot, response_slot, palette, pixels, len(result[4]), frame_time(response_slot), monotonic())
    return {'scheduled_tics': last_tic - first_tic, 'scheduled_frames': last_slot,
            'frame_requests': frames, 'skipped_frames': skipped + max(0, last_slot + 1 - slot),
            'stale_frames': stale, 'last_tic': acknowledged, 'tick_debt': last_tic - acknowledged,
            'undrained_requests': writer.pending + reader.pending}


def pipeline_limit(rtt_ms):
    return max(2, ceil(rtt_ms * TIC_RATE / 1000) + 1)
