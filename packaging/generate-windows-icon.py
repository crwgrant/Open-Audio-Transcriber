#!/usr/bin/env python3
"""Build a multi-resolution Windows .ico from packaging/app-icon.png."""

from __future__ import annotations

import io
import struct
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError as exc:  # pragma: no cover
    raise SystemExit("Pillow is required: pip install pillow") from exc

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "app-icon.png"
OUT = ROOT / "audio-transcriber.ico"
SIZES = (16, 24, 32, 48, 64, 128, 256)


def png_bytes_for_size(source: Image.Image, size: int) -> bytes:
    resized = source.resize((size, size), Image.Resampling.LANCZOS)
    buf = io.BytesIO()
    resized.save(buf, format="PNG")
    return buf.getvalue()


def write_ico(path: Path, png_images: list[bytes]) -> None:
    count = len(png_images)
    header_size = 6 + count * 16
    offset = header_size

    with path.open("wb") as f:
        f.write(struct.pack("<HHH", 0, 1, count))

        entries: list[bytes] = []
        for size, png in zip(SIZES, png_images):
            w = struct.unpack(">I", png[16:20])[0]
            h = struct.unpack(">I", png[20:24])[0]
            width_byte = 0 if w >= 256 else w
            height_byte = 0 if h >= 256 else h
            entry = struct.pack(
                "<BBBBHHII",
                width_byte,
                height_byte,
                0,
                0,
                1,
                32,
                len(png),
                offset,
            )
            entries.append(entry)
            offset += len(png)

        for entry in entries:
            f.write(entry)
        for png in png_images:
            f.write(png)


def main() -> int:
    if not SRC.is_file():
        print(f"error: missing {SRC}", file=sys.stderr)
        return 1

    source = Image.open(SRC).convert("RGBA")
    png_images = [png_bytes_for_size(source, size) for size in SIZES]
    write_ico(OUT, png_images)
    print(f"Wrote {OUT} ({OUT.stat().st_size} bytes, sizes: {', '.join(map(str, SIZES))})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
