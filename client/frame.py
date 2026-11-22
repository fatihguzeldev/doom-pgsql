from struct import Struct


WIDTH = 160
HEIGHT = 100
PIXELS = WIDTH * HEIGHT
VERTICAL = 0x4000
HEADER = Struct('!HBB')


def unpack_frame(payload):
    colors = bytearray(PIXELS)
    shades = bytearray(PIXELS)
    coverage = bytearray(PIXELS)
    offset = 0
    written = 0
    while offset < len(payload):
        if len(payload) - offset < HEADER.size:
            raise ValueError('truncated frame header')
        position, count, shade = HEADER.unpack_from(payload, offset)
        offset += HEADER.size
        start = position & (VERTICAL - 1)
        stride = WIDTH if position & VERTICAL else 1
        limit = HEIGHT - start // WIDTH if stride == WIDTH else WIDTH - start % WIDTH
        if position & 0x8000 or start >= PIXELS or not 0 < count <= limit or offset + count > len(payload):
            raise ValueError('invalid frame run bounds')
        target = slice(start, start + stride * count, stride)
        colors[target] = payload[offset:offset + count]
        shades[target] = bytes((shade,)) * count
        coverage[target] = b'\x01' * count
        written += count
        offset += count
    if written != PIXELS or coverage.count(1) != PIXELS:
        raise ValueError('frame must cover every pixel exactly once')
    return colors, shades
