#!/usr/bin/env python3
"""Generate the Earned app icon.

The mark is `E.` — the app's own poster lockup. `Theme.StateWord` renders every
state as `Text(word) + Text(".")` with the full stop in signal red, so the red
dot is the brand mark and the icon is just that lockup at its shortest.

Deliberately geometric rather than typeset: the letterform is four rectangles,
so it needs no font, matches the square-cornered poster idiom, and stays crisp
at 40px on a home screen.

Written by hand because this container has no image libraries — and kept in the
repo so the icon is reproducible rather than an unexplained binary.

    python3 tools/make-appicon.py

Writes app/Earned/Assets.xcassets/AppIcon.appiconset/icon-1024.png
"""

import pathlib
import struct
import zlib

SIZE = 1024

# docs/design-language.md, mirrored in app/Earned/Design/Theme.swift
PAPER = (242, 239, 233)   # #F2EFE9
INK = (20, 18, 16)        # #141210
SIGNAL = (232, 68, 46)    # #E8442E

# Geometry. Margins are equal left and right (222px), so the lockup sits
# centred inside iOS's rounded-corner mask with room to spare.
E_LEFT, E_RIGHT = 222, 602
E_TOP, E_BOTTOM = 232, 792
STROKE = 118
MIDDLE_ARM_RIGHT = 532            # shorter, as a letter E's middle arm is
DOT_RADIUS = 70
DOT_CX = E_RIGHT + 60 + DOT_RADIUS  # 732
DOT_CY = E_BOTTOM - DOT_RADIUS      # 722 — the full stop sits on the baseline


def blank(color):
    row = bytes(color) * SIZE
    return bytearray(row * SIZE)


def fill_rect(buf, x0, y0, x1, y1, color):
    """Axis-aligned and integer-aligned, so no antialiasing is needed."""
    span = bytes(color) * (x1 - x0)
    for y in range(y0, y1):
        start = (y * SIZE + x0) * 3
        buf[start:start + len(span)] = span


def fill_circle(buf, cx, cy, radius, color):
    """4x4 supersampled coverage, over the dot's bounding box only."""
    samples = [(i + 0.5) / 4.0 for i in range(4)]
    r2 = radius * radius
    for y in range(int(cy - radius) - 1, int(cy + radius) + 2):
        if not 0 <= y < SIZE:
            continue
        for x in range(int(cx - radius) - 1, int(cx + radius) + 2):
            if not 0 <= x < SIZE:
                continue
            hits = 0
            for sy in samples:
                dy = y + sy - cy
                for sx in samples:
                    dx = x + sx - cx
                    if dx * dx + dy * dy <= r2:
                        hits += 1
            if hits == 0:
                continue
            i = (y * SIZE + x) * 3
            if hits == 16:
                buf[i:i + 3] = bytes(color)
            else:
                a = hits / 16.0
                for c in range(3):
                    buf[i + c] = round(buf[i + c] * (1 - a) + color[c] * a)


def encode_png(width, height, buf):
    raw = bytearray()
    stride = width * 3
    for y in range(height):
        raw.append(0)  # filter type 0 (None)
        raw += buf[y * stride:(y + 1) * stride]

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    # Colour type 2 = truecolour, no alpha. iOS app icons must be opaque.
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", header)
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + chunk(b"IEND", b""))


def main():
    buf = blank(PAPER)
    fill_rect(buf, E_LEFT, E_TOP, E_LEFT + STROKE, E_BOTTOM, INK)        # stem
    fill_rect(buf, E_LEFT, E_TOP, E_RIGHT, E_TOP + STROKE, INK)          # top arm
    middle_top = (E_TOP + E_BOTTOM) // 2 - STROKE // 2
    fill_rect(buf, E_LEFT, middle_top, MIDDLE_ARM_RIGHT, middle_top + STROKE, INK)
    fill_rect(buf, E_LEFT, E_BOTTOM - STROKE, E_RIGHT, E_BOTTOM, INK)    # bottom arm
    fill_circle(buf, DOT_CX, DOT_CY, DOT_RADIUS, SIGNAL)                 # the brand mark

    out = (pathlib.Path(__file__).resolve().parent.parent
           / "app/Earned/Assets.xcassets/AppIcon.appiconset/icon-1024.png")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(encode_png(SIZE, SIZE, buf))
    print(f"wrote {out} ({out.stat().st_size:,} bytes)")


if __name__ == "__main__":
    main()
