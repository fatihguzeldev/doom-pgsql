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
TICK_GAP = 'PDT01'


def run(writer, reader, game, epoch, first_tic, input_at, on_frame, on_tick,
        *, duration=None, in_flight=3, drain_timeout=3.0, reconnect=None, reconnect_limit=2):
    if in_flight < 1 or (duration is not None and duration <= 0) or reconnect_limit < 0:
        raise ValueError('invalid queue limit, duration or reconnection limit')
    start = monotonic() + 0.025
    end = float('inf') if duration is None else start + duration
    last_tic = None if duration is None else first_tic + round(duration * TIC_RATE)
    last_slot = None if duration is None else round(duration * FRAME_RATE)
    tic, acknowledged, slot, displayed = first_tic + 1, first_tic, 1, first_tic - 1
    commands = {}
    last_payload = last_palette = None
    retry = False
    terminal_tic = None
    drain_at = end + drain_timeout
    replay_through = first_tic
    reconnects = skipped = stale = frames = 0

    def tick_time(number):
        return start + (number - first_tic - 1) / TIC_RATE

    def frame_time(number):
        return start + (number - 0.5) / FRAME_RATE

    def request_frame(number):
        nonlocal frames
        reader.send(number, game, epoch, number)
        frames += 1

    while True:
        now = monotonic()
        active = terminal_tic is None and now < end
        need_final_frame = terminal_tic is not None and displayed < terminal_tic
        if not active and (now >= drain_at or not (reader.pending or writer.pending or need_final_frame)):
            break

        if retry and not writer.pending:
            tic = acknowledged + 1
            retry = False

        try:
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
                    request_frame(current)
                else:
                    skipped += 1
            if need_final_frame and not reader.pending:
                request_frame(slot)
                slot += 1

            lanes = (writer, reader)
            deadline = end if active else drain_at
            if active:
                if not retry and writer.pending < in_flight and (last_tic is None or tic <= last_tic):
                    deadline = min(deadline, tick_time(tic))
                if last_slot is None or slot <= last_slot:
                    deadline = min(deadline, frame_time(slot))
            readable, writable, _ = select([lane.fd for lane in lanes], [lane.fd for lane in lanes if lane.wants_write],
                                           [], None if deadline == float('inf') else max(0, deadline - monotonic()))
            tick_results = writer.poll(writer.fd in readable, writer.fd in writable)
            frame_results = reader.poll(reader.fd in readable, reader.fd in writable)
        except ConnectionError as lost_connection:
            if reconnect is None or reconnects >= reconnect_limit:
                raise
            skipped += reader.pending
            reader.close()
            writer.close()
            # A Sync may have committed before the socket failed. Resend exactly the original input.
            replay_through = max(replay_through, max(commands, default=acknowledged))
            while True:
                reconnects += 1
                try:
                    writer, reader = reconnect()
                    break
                except ConnectionError:
                    if reconnects >= reconnect_limit:
                        raise lost_connection
            tic = acknowledged + 1
            retry = False
            continue

        for tag, result in tick_results:
            if isinstance(result, SqlError):
                if result.code in ('40001', '40P01') or (retry and result.code == TICK_GAP):
                    retry = True
                    continue
                raise result
            accepted = integer(result[0])
            if accepted < tag:
                if accepted != acknowledged:
                    raise ValueError('finished tick does not match the confirmed sequence')
                if terminal_tic is None:
                    terminal_tic = accepted
                    drain_at = min(drain_at, monotonic() + drain_timeout)
                continue
            if tag != acknowledged + 1 or (accepted > tag and tag > replay_through):
                raise ValueError('tick response does not match the confirmed sequence')
            acknowledged = tag
            commands.pop(tag, None)
            on_tick(tag, tick_time(tag), monotonic())

        for tag, result in frame_results:
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

    scheduled_tics = (last_tic if last_tic is not None else max(tic - 1, acknowledged)) - first_tic
    scheduled_frames = last_slot if last_slot is not None else slot - 1
    return {'scheduled_tics': scheduled_tics, 'scheduled_frames': scheduled_frames,
            'frame_requests': frames, 'skipped_frames': skipped + max(0, scheduled_frames + 1 - slot),
            'stale_frames': stale, 'last_tic': acknowledged,
            'tick_debt': scheduled_tics - (acknowledged - first_tic) if terminal_tic is None else 0,
            'undrained_requests': writer.pending + reader.pending,
            'finished_at_tic': terminal_tic, 'reconnects': reconnects}


def pipeline_limit(rtt_ms):
    return max(2, ceil(rtt_ms * TIC_RATE / 1000) + 1)
