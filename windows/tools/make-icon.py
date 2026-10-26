#!/usr/bin/env python3
"""Build the Windows app icon (PopGuy.ico) from assets/logo_1024.png.

Re-run this after changing the logo, then commit the regenerated .ico:

    python3 windows/tools/make-icon.py

Runs on the Mac (uses macOS `sips` to resize). Python 3 stdlib only.
The ICO holds one PNG-compressed entry per size.

    python3 windows/tools/make-icon.py --tray

builds the tray icons instead, TrayIcon-light.ico (a black glyph, for a light taskbar) and TrayIcon-dark.ico (a white
glyph, for a dark taskbar), from the macOS menu bar template image
(macos/PopGuy/Assets.xcassets/MenuBarIcon.imageset): only its alpha is kept, as macOS does for a template image.
Needs Pillow.
"""

import argparse
import io
import struct
import subprocess
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SOURCE = REPO_ROOT / "assets" / "logo_1024.png"
OUTPUT = REPO_ROOT / "windows" / "src" / "PopGuy.App" / "Assets" / "PopGuy.ico"
SIZES = [16, 20, 24, 32, 40, 48, 64, 256]

TRAY_SOURCE = REPO_ROOT / "macos" / "PopGuy" / "Assets.xcassets" / "MenuBarIcon.imageset" / "MenuBarIcon@2x.png"
TRAY_OUTPUTS = {
    OUTPUT.parent / "TrayIcon-light.ico": (0, 0, 0),
    OUTPUT.parent / "TrayIcon-dark.ico": (255, 255, 255),
}
# The small icon size at 100-300 % scaling (the notification area shows SM_CXSMICON).
TRAY_SIZES = [16, 20, 24, 32, 40, 48]


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


def tray_frame(alpha, size: int, color: tuple[int, int, int]) -> bytes:
    from PIL import Image  # only --tray needs Pillow

    glyph = Image.new("RGBA", (size, size), color + (0,))
    glyph.putalpha(alpha.resize((size, size), Image.Resampling.LANCZOS))
    out = io.BytesIO()
    glyph.save(out, format="PNG")
    return out.getvalue()


def make_tray() -> None:
    from PIL import Image  # only --tray needs Pillow

    # A template image: the colour channels are ignored, the alpha is the glyph.
    alpha = Image.open(TRAY_SOURCE).convert("RGBA").getchannel("A")
    for output, color in TRAY_OUTPUTS.items():
        images = [(size, tray_frame(alpha, size, color)) for size in TRAY_SIZES]
        output.write_bytes(build_ico(images))
        print(f"Wrote {output.relative_to(REPO_ROOT)} ({', '.join(map(str, TRAY_SIZES))} px)")


def main() -> None:
    parser = argparse.ArgumentParser(description="Build the Windows app icon, or the tray icons with --tray.")
    parser.add_argument("--tray", action="store_true", help="build TrayIcon-light.ico and TrayIcon-dark.ico")
    if parser.parse_args().tray:
        make_tray()
        return
    with tempfile.TemporaryDirectory() as tmp:
        images = [(size, resize(SOURCE, size, Path(tmp))) for size in SIZES]
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_bytes(build_ico(images))
    print(f"Wrote {OUTPUT.relative_to(REPO_ROOT)} ({', '.join(map(str, SIZES))} px)")


if __name__ == "__main__":
    main()
