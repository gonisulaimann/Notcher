#!/usr/bin/env python3
"""Pixel-profile the housing band in notch snapshot PNGs (stdlib only).

The island canvas is 440x594pt @2x = 880x1188px, top-anchored. The hardware
housing occupies the top 32pt = rows 0..63. For each row band this reports
mean luminance (0-255) so a reviewer can verify that no bright content sits
inside the housing band: dark chin expected (~10-40), anything sustained
above ~120 inside rows 8..56 is a leak.

Usage: profile-band.py <png> [png...]
"""
import struct
import sys
import zlib


def read_png(path):
    with open(path, "rb") as f:
        data = f.read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a png"
    pos, w, h, ctype, bitd, interlace = 8, 0, 0, 0, 0, 0
    raw = b""
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        ctype_b = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + length]
        if ctype_b == b"IHDR":
            w, h, bitd, ctype, _, _, interlace = struct.unpack(">IIBBBBB", chunk)
        elif ctype_b == b"IDAT":
            raw += chunk
        pos += 12 + length
    assert interlace == 0, "interlaced not supported"
    assert bitd == 8 and ctype in (2, 6), f"unsupported: bitdepth={bitd} colortype={ctype}"
    ch = 3 if ctype == 2 else 4
    px = zlib.decompress(raw)
    stride = w * ch
    out = bytearray(w * h * 3)
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        f = px[p]
        p += 1
        line = bytearray(px[p:p + stride])
        p += stride
        if f == 1:
            for i in range(ch, stride):
                line[i] = (line[i] + line[i - ch]) & 0xFF
        elif f == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif f == 3:
            for i in range(stride):
                a = line[i - ch] if i >= ch else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif f == 4:
            for i in range(stride):
                a = line[i - ch] if i >= ch else 0
                b = prev[i]
                c = prev[i - ch] if i >= ch else 0
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        elif f != 0:
            raise ValueError(f"bad filter {f}")
        for x in range(w):
            o = (y * w + x) * 3
            s = y * 0  # noqa
            r, g, b = line[x * ch], line[x * ch + 1], line[x * ch + 2]
            if ch == 4:
                a = line[x * ch + 3] / 255.0
                # composite over mid-gray (menu-bar-ish) for alpha pixels
                r = r * a + 128 * (1 - a)
                g = g * a + 128 * (1 - a)
                b = b * a + 128 * (1 - a)
            out[o:o + 3] = bytes((int(r), int(g), int(b)))
        prev = line
    return w, h, out


def band_mean(w, h, px, y0, y1, x0=None, x1=None):
    x0 = 0 if x0 is None else x0
    x1 = w if x1 is None else x1
    total, n = 0, 0
    for y in range(y0, min(y1, h)):
        for x in range(x0, x1):
            o = (y * w + x) * 3
            total += 0.2126 * px[o] + 0.7152 * px[o + 1] + 0.0722 * px[o + 2]
            n += 1
    return total / max(n, 1)


for path in sys.argv[1:]:
    w, h, px = read_png(path)
    # housing band: rows 0..63 (32pt @2x); skip top/bottom 4px edge rows
    housing = band_mean(w, h, px, 8, 56)
    # just-below band: rows 64..127 (where body content may legitimately live)
    below = band_mean(w, h, px, 64, 128)
    # housing band restricted to the chin center (notch x-range ≈ center 179pt→358px)
    cx0, cx1 = w // 2 - 179, w // 2 + 179
    chin = band_mean(w, h, px, 8, 56, cx0, cx1)
    print(f"{path}: {w}x{h} housing={housing:.0f} chin-center={chin:.0f} below={below:.0f}")
