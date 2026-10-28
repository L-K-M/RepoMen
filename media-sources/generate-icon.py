#!/usr/bin/env python3
"""Export the illustrated master to every macOS app-icon size.

The artwork lives in media-sources/icon.png (1024px RGBA). This script only
updates the asset catalog; it never overwrites the master.

Requirements: Python 3 and macOS (uses the built-in sips image resampler).
Run from any directory:
  python3 media-sources/generate-icon.py
"""

import shutil
import struct
import subprocess
from pathlib import Path


REPO = Path(__file__).resolve().parent.parent
MASTER = REPO / "media-sources/icon.png"
ICONSET = REPO / "RepoMen/Resources/Assets.xcassets/AppIcon.appiconset"
SIZES = (16, 32, 64, 128, 256, 512, 1024)


def main():
    # Reject an unsuitable master before touching any catalog images.
    with MASTER.open("rb") as source:
        header = source.read(29)
    if len(header) != 29 or header[:16] != b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR":
        raise ValueError(f"Expected a PNG master: {MASTER}")
    width, height, depth, color, _, _, _ = struct.unpack(">IIBBBBB", header[16:29])
    if (width, height, depth, color) != (1024, 1024, 8, 6):
        raise ValueError(f"Expected a 1024x1024, 8-bit RGBA master: {MASTER}")

    ICONSET.mkdir(parents=True, exist_ok=True)
    for size in SIZES:
        destination = ICONSET / f"AppIcon-{size}.png"
        if size == 1024:
            shutil.copyfile(MASTER, destination)
        else:
            subprocess.run(
                ["/usr/bin/sips", "--resampleHeightWidth", str(size), str(size),
                 str(MASTER), "--out", str(destination)],
                check=True,
                stdout=subprocess.DEVNULL,
            )
        print(f"wrote {destination.relative_to(REPO)} ({size}x{size})")


if __name__ == "__main__":
    main()
