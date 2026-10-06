#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Prepend the TRENDnet/U-Media upgrade header used by the TEW-829DRU stock web UI.

Header (18 bytes, ASCII): "UR_C" + 6-char board id + 8 hex digits CRC.
The CRC is CRC-32/MPEG-2 (poly 0x04c11db7, init 0xffffffff, no reflection,
no final xor) over everything after the header. The stock um_handle_header
checks the board id against `um_art r bid` and accepts "ffffff" as a wildcard.
"""
import sys

MAGIC = b"UR_C"
BOARD_ID = b"053192"  # from TEW-829DRU_v1.0.3.12.bin


def _table():
    t = []
    for i in range(256):
        c = i << 24
        for _ in range(8):
            c = ((c << 1) ^ 0x04C11DB7) if c & 0x80000000 else (c << 1)
            c &= 0xFFFFFFFF
        t.append(c)
    return t


def crc32_mpeg2(data):
    t = _table()
    c = 0xFFFFFFFF
    for b in data:
        c = ((c << 8) & 0xFFFFFFFF) ^ t[((c >> 24) ^ b) & 0xFF]
    return c


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: tew829-header.py <in> <out>")
    with open(sys.argv[1], "rb") as f:
        body = f.read()
    hdr = MAGIC + BOARD_ID + b"%08x" % crc32_mpeg2(body)
    assert len(hdr) == 18
    with open(sys.argv[2], "wb") as f:
        f.write(hdr + body)


if __name__ == "__main__":
    main()
