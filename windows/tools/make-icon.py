#!/usr/bin/env python3
"""Build the Windows app icon (PopGuy.ico) from assets/logo_1024.png.

Re-run this after changing the logo, then commit the regenerated .ico:

    python3 windows/tools/make-icon.py

Runs on the Mac (uses macOS `sips` to resize). Python 3 stdlib only.
The ICO holds one PNG-compressed entry per size.
"""

import struct
import subprocess
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SOURCE = REPO_ROOT / "assets" / "logo_1024.png"
OUTPUT = REPO_ROOT / "windows" / "src" / "PopGuy.App" / "Assets" / "PopGuy.ico"
SIZES = [16, 20, 24, 32, 40, 48, 64, 256]


def resize(source: Path, size: int, out_dir: Path) -> bytes:
    out = out_dir / f"{size}.png"
    subprocess.run(
        ["sips", "-z", str(size), str(size), str(source), "--out", str(out)],
        check=True,
        capture_output=True,
    )
    return out.read_bytes()


def build_ico(images: list[tuple[int, bytes]]) -> bytes:
    # ICONDIR: reserved, type (1 = icon), image count.
    header = struct.pack("<HHH", 0, 1, len(images))
    entries = b""
    offset = len(header) + 16 * len(images)
    for size, png in images:
        dim = 0 if size >= 256 else size  # 0 means 256 px
        # ICONDIRENTRY: width, height, colors, reserved, planes, bpp, size, offset.
        entries += struct.pack("<BBBBHHII", dim, dim, 0, 0, 1, 32, len(png), offset)
        offset += len(png)
    return header + entries + b"".join(png for _, png in images)


def main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        images = [(size, resize(SOURCE, size, Path(tmp))) for size in SIZES]
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_bytes(build_ico(images))
    print(f"Wrote {OUTPUT.relative_to(REPO_ROOT)} ({', '.join(map(str, SIZES))} px)")


if __name__ == "__main__":
    main()
