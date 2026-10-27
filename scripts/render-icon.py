#!/usr/bin/env python3
"""Draw the app icon with the standard library only."""

import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "MeetingRecorder" / "Assets.xcassets" / "AppIcon.appiconset"


def inside_round_rect(x: float, y: float, size: float, radius: float) -> bool:
    half = size / 2
    qx = abs(x - half) - (half - radius)
    qy = abs(y - half) - (half - radius)
    outside = (max(qx, 0) ** 2 + max(qy, 0) ** 2) ** 0.5
    inside = min(max(qx, qy), 0)
    return outside + inside <= 0


def paint(size: int):
    bg = (20, 52, 44, 255)
    ring = (243, 237, 226, 255)
    red = (226, 61, 47, 255)
    radius = size * 0.22
    cx = cy = size / 2
    outer = size * 0.30
    inner = size * 0.22
    dot = size * 0.11
    rows = []
    for y in range(size):
        row = bytearray()
        for x in range(size):
            px = x + 0.5
            py = y + 0.5
            if not inside_round_rect(px, py, size, radius):
                row.extend((0, 0, 0, 0))
                continue
            dist = ((px - cx) ** 2 + (py - cy) ** 2) ** 0.5
            if dist <= dot:
                color = red
            elif inner <= dist <= outer:
                color = ring
            else:
                color = bg
            row.extend(color)
        rows.append(bytes(row))
    return rows


def downsample(rows, src: int, dst: int):
    factor = src // dst
    out = []
    for y in range(dst):
        row = bytearray()
        for x in range(dst):
            acc = [0, 0, 0, 0]
            count = 0
            for yy in range(y * factor, (y + 1) * factor):
                source = rows[yy]
                for xx in range(x * factor, (x + 1) * factor):
                    i = xx * 4
                    pr, pg, pb, pa = source[i : i + 4]
                    acc[0] += pr * pa
                    acc[1] += pg * pa
                    acc[2] += pb * pa
                    acc[3] += pa
                    count += 1
            if acc[3]:
                r, g, b = (channel // acc[3] for channel in acc[:3])
            else:
                r = g = b = 0
            a = acc[3] // count
            row.extend((r, g, b, a))
        out.append(bytes(row))
    return out


def write_png(path: Path, rows) -> None:
    height = len(rows)
    width = len(rows[0]) // 4

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    raw = b"".join(b"\x00" + row for row in rows)
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    path.write_bytes(png)


def main() -> None:
    master_size = 1024
    master = paint(master_size)
    OUT.mkdir(parents=True, exist_ok=True)
    for size in (16, 32, 64, 128, 256, 512, 1024):
        rows = master if size == master_size else downsample(master, master_size, size)
        write_png(OUT / f"icon_{size}.png", rows)
        print(f"wrote icon_{size}.png")


if __name__ == "__main__":
    main()
