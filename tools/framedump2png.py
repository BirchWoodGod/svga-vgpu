#!/usr/bin/env python3
"""Convert vmvga frame dumps (sid<N>_fmt<F>_<W>x<H>_pitch<P>.raw) to PNGs.

    tools/framedump2png.py build/framedump-HHMMSS

Writes <name>.png next to each .raw and prints per-surface statistics
(min/max/mean of the colour channels), so empty or all-black targets stand
out. Float formats are shown clamped to 0..1.
"""
import re
import sys
from pathlib import Path

import numpy as np
from PIL import Image

NAME = re.compile(r"sid(\d+)_fmt(\d+)_(\d+)x(\d+)_pitch(\d+)(?:_shadow)?\.raw$")


FOURCC = {15: b"DXT1", 17: b"DXT3", 19: b"DXT5", 111: b"ATI2"}


def decode_dds(fourcc, raw, w, h):
    """Wrap one compressed level in a minimal DDS header and let Pillow decode it."""
    import io
    import struct

    header = struct.pack(
        "<4sIIIIIII44sII4s20sI16s",
        b"DDS ", 124, 0x1 | 0x2 | 0x4 | 0x1000 | 0x80000, h, w, len(raw), 0, 1,
        b"\0" * 44, 32, 0x4, fourcc, b"\0" * 20, 0x1000, b"\0" * 16)
    assert len(header) == 128
    img = Image.open(io.BytesIO(header + raw)).convert("RGB")
    return np.asarray(img).astype(np.float32) / 255.0


def decode(fmt, raw, w, h, pitch):
    if fmt in FOURCC:
        return decode_dds(FOURCC[fmt], raw, w, h)
    rows = np.frombuffer(raw, dtype=np.uint8)[: pitch * h].reshape(h, pitch)
    if fmt in (1, 2):  # X8R8G8B8 / A8R8G8B8, bytes B G R A
        px = rows[:, : w * 4].reshape(h, w, 4)
        rgb = px[:, :, [2, 1, 0]].astype(np.float32) / 255.0
    elif fmt == 3:  # R5G6B5
        v = rows[:, : w * 2].copy().view("<u2").reshape(h, w).astype(np.uint32)
        rgb = np.stack([(v >> 11) / 31.0, ((v >> 5) & 63) / 63.0, (v & 31) / 31.0], axis=2)
    elif fmt == 24:  # ARGB_S10E5 = A16B16G16R16F, halves R G B A
        rgb = rows[:, : w * 8].copy().view("<f2").reshape(h, w, 4)[:, :, :3].astype(np.float32)
    elif fmt == 34:  # R_S23E8 = R32F
        r = rows[:, : w * 4].copy().view("<f4").reshape(h, w).astype(np.float32)
        rgb = np.stack([r, r, r], axis=2)
    elif fmt == 35:  # RG_S10E5 = G16R16F
        rg = rows[:, : w * 4].copy().view("<f2").reshape(h, w, 2).astype(np.float32)
        rgb = np.stack([rg[:, :, 0], rg[:, :, 1], np.zeros((h, w), np.float32)], axis=2)
    elif fmt == 41:  # A16B16G16R16 unorm, R G B A
        rgb = rows[:, : w * 8].copy().view("<u2").reshape(h, w, 4)[:, :, :3].astype(np.float32) / 65535.0
    else:
        return None
    return rgb


def main():
    folder = Path(sys.argv[1])
    for path in sorted(folder.glob("*.raw"), key=lambda p: int(NAME.search(p.name).group(1))):
        sid, fmt, w, h, pitch = map(int, NAME.search(path.name).groups())
        rgb = decode(fmt, path.read_bytes(), w, h, pitch)
        if rgb is None:
            print(f"sid {sid:4d} fmt {fmt:3d} {w}x{h}: unsupported format")
            continue
        finite = np.nan_to_num(rgb, nan=0.0, posinf=0.0, neginf=0.0)
        print(f"sid {sid:4d} fmt {fmt:3d} {w:4d}x{h:<4d} min {finite.min():9.4f} "
              f"max {finite.max():9.4f} mean {finite.mean():8.4f} "
              f"nan {np.isnan(rgb).sum():7d} inf {np.isinf(rgb).sum():7d}")
        img = (np.clip(finite, 0.0, 1.0) * 255.0 + 0.5).astype(np.uint8)
        Image.fromarray(img, "RGB").save(path.with_suffix(".png"))


if __name__ == "__main__":
    main()
