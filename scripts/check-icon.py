#!/usr/bin/env python3
"""Checks the app icon "Bausteine" (card 950D1506): package structure, target wiring, ictool render, built apps.

Usage: scripts/check-icon.py [--render-dir DIR] [--app PATH.app ...]
  --render-dir  keep the ictool renderings (default: a temporary directory)
  --app         additionally check a built app bundle (iOS, macOS or watchOS)
Headless: runs the `ictool` and `assetutil` command line tools only, never opens Icon Composer.
Env: ICTOOL overrides the ictool path. Exit code 0 = everything holds, 1 = at least one check failed.
"""
import argparse
import json
import os
import plistlib
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PACKAGE = ROOT / "App" / "Icon" / "AppIcon.icon"
ASSETS = {"block-next.svg", "blocks-done.svg"}
TARGETS = ("Todo-iOS", "Todo-macOS", "Todo-watchOS")
ICTOOL = os.environ.get(
    "ICTOOL", "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool")
VIEWS = (("ios-default", "iOS", "Default"), ("ios-dark", "iOS", "Dark"),
         ("macos-default", "macOS", "Default"), ("macos-dark", "macOS", "Dark"),
         ("watchos-default", "watchOS", "Default"))
# Block centres on the 1024 canvas: the three done blocks and the next one (top right) form the check mark.
DONE = ((230, 528), (410, 708), (590, 528))
NEXT = (770, 348)
EMPTY = ((230, 250), (770, 800))

failures = []


def check(ok, message):
    print(("ok    " if ok else "FAIL  ") + message)
    if not ok:
        failures.append(message)


def mixed_fills(node):
    if isinstance(node, dict):
        return ("fill" in node and "fill-specializations" in node) or any(mixed_fills(v) for v in node.values())
    return isinstance(node, list) and any(mixed_fills(v) for v in node)


def check_package():
    manifest = PACKAGE / "icon.json"
    found = {p.name for p in (PACKAGE / "Assets").glob("*")}
    check(found == ASSETS, f"package assets are {sorted(ASSETS)} (found {sorted(found)})")
    check(not (ROOT / "App" / "Icon" / "source").exists(), "old icon source App/Icon/source is gone")
    if not manifest.is_file():
        check(False, "App/Icon/AppIcon.icon/icon.json exists")
        return
    icon = json.loads(manifest.read_text())
    groups = icon.get("groups", [])
    check([g.get("name") for g in groups] == ["Next block", "Done blocks"], "front group (first) is 'Next block'")
    images = {layer.get("image-name") for g in groups for layer in g.get("layers", [])}
    check(images == found, f"layers use exactly the packaged assets (layers {sorted(map(str, images))})")
    check(not mixed_fills(icon), "no 'fill' next to 'fill-specializations'")
    check("watchOS" in icon.get("supported-platforms", {}).get("circles", []), "watchOS circle is supported")


def check_targets():
    dump = subprocess.run(["xcodegen", "dump", "--type", "json", "--spec", str(ROOT / "project.yml")],
                          capture_output=True, text=True, check=True).stdout
    targets = json.loads(dump)["targets"]
    for name in TARGETS:
        sources = [s if isinstance(s, str) else s.get("path") for s in targets[name].get("sources", [])]
        check("App/Icon/AppIcon.icon" in sources, f"{name} compiles App/Icon/AppIcon.icon")
        setting = targets[name].get("settings", {}).get("base", {}).get("ASSETCATALOG_COMPILER_APPICON_NAME")
        check(setting == "AppIcon", f"{name} sets ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon (found {setting})")


def read_png(path):
    """Returns a pixel(x, y) -> (r, g, b) reader (0..255) for a non-interlaced 8 or 16 bit RGB(A) PNG."""
    data = path.read_bytes()
    at, idat = 8, b""
    while at < len(data):
        length, kind = struct.unpack(">I4s", data[at:at + 8])
        chunk = data[at + 8:at + 8 + length]
        if kind == b"IHDR":
            width, height, depth, colour, _, _, interlace = struct.unpack(">IIBBBBB", chunk)
        elif kind == b"IDAT":
            idat += chunk
        at += length + 12
    if depth not in (8, 16) or colour not in (2, 6) or interlace:
        raise ValueError(f"unsupported PNG {path}: depth {depth}, colour type {colour}")
    channels, sample = (4 if colour == 6 else 3), depth // 8
    step, stride = channels * sample, width * channels * sample
    raw, rows, previous = zlib.decompress(idat), [], bytearray(stride)
    for y in range(height):
        start = y * (stride + 1)
        kind, row = raw[start], bytearray(raw[start + 1:start + 1 + stride])
        for x in range(stride):
            a = row[x - step] if x >= step else 0
            b, c = previous[x], previous[x - step] if x >= step else 0
            if kind == 1:
                row[x] = (row[x] + a) & 255
            elif kind == 2:
                row[x] = (row[x] + b) & 255
            elif kind == 3:
                row[x] = (row[x] + (a + b) // 2) & 255
            elif kind == 4:
                p = a + b - c
                best = min((abs(p - a), 0, a), (abs(p - b), 1, b), (abs(p - c), 2, c))[2]
                row[x] = (row[x] + best) & 255
        rows.append(row)
        previous = row

    def pixel(x, y):
        i = (y * height // 1024) , (x * width // 1024) * step
        return tuple(rows[i[0]][i[1] + n * sample] for n in range(3))

    return pixel


def red(c):
    return c[0] > 180 and c[1] < 140 and c[2] < 130


def yellow(c):
    return c[0] > 200 and c[1] > 140 and c[2] < 140


def navy(c):
    return c[0] < 90 and c[1] < 100 and c[2] < 150 and c[2] > c[0]


def black(c):
    return max(c) < 60


def render(directory):
    directory.mkdir(parents=True, exist_ok=True)
    for name, platform, rendition in VIEWS:
        target = directory / f"{name}.png"
        run = subprocess.run([ICTOOL, str(PACKAGE), "--export-image", "--output-file", str(target),
                              "--platform", platform, "--rendition", rendition,
                              "--width", "512", "--height", "512", "--scale", "1"], capture_output=True, text=True)
        check(run.returncode == 0 and target.is_file(), f"ictool renders {name}"
              + ("" if run.returncode == 0 else f": {run.stderr.strip() or run.stdout.strip()}"))
    for name, background, done in (("ios-default", yellow, navy), ("ios-dark", black, yellow)):
        target = directory / f"{name}.png"
        if not target.is_file():
            continue
        pixel = read_png(target)
        check(red(pixel(*NEXT)), f"{name}: red block top right {pixel(*NEXT)}")
        for point in DONE:
            check(done(pixel(*point)), f"{name}: done block at {point} is {done.__name__} {pixel(*point)}")
        for point in EMPTY:
            check(background(pixel(*point)), f"{name}: background at {point} is {background.__name__} {pixel(*point)}")


def check_app(app):
    contents = app / "Contents" if (app / "Contents").is_dir() else app
    resources = contents / "Resources" if contents != app else app
    label = app.name
    info = plistlib.loads((contents / "Info.plist").read_bytes())
    platform = info.get("DTPlatformName", "?")
    label = f"{app.name} ({platform})"
    icons = info.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon", {})
    name = info.get("CFBundleIconName") or icons.get("CFBundleIconName")
    check(name == "AppIcon", f"{label}: Info.plist names the icon AppIcon (found {name})")
    catalog = resources / "Assets.car"
    if not catalog.is_file():
        check(False, f"{label}: Assets.car exists")
        return
    listing = subprocess.run(["xcrun", "assetutil", "--info", str(catalog)],
                             capture_output=True, text=True, check=True).stdout
    names = sorted({str(e.get("Name")) for e in json.loads(listing) if e.get("Name")})
    check("AppIcon" in names, f"{label}: Assets.car holds AppIcon")
    for layer in ("block-next", "blocks-done"):
        check(any(layer in n for n in names), f"{label}: Assets.car holds the layer {layer}")
    stale = [n for n in names if any(old in n for old in ("checkmark", "project-root", "project-child", "project-task"))]
    check(not stale, f"{label}: no layer of the old icon left {stale}")
    # Systems before 26 need flat fallback images.
    if platform.startswith("macosx"):
        check((resources / "AppIcon.icns").is_file(), f"{label}: fallback AppIcon.icns for older macOS")
    elif platform.startswith("iphone"):
        check(any(app.glob("AppIcon60x60*.png")), f"{label}: fallback AppIcon60x60 PNG for older iOS")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--render-dir", type=Path)
    parser.add_argument("--app", type=Path, action="append", default=[])
    args = parser.parse_args()
    check_package()
    check_targets()
    with tempfile.TemporaryDirectory() as scratch:
        render(args.render_dir or Path(scratch))
    for app in args.app:
        check_app(app)
    print(f"check-icon: {len(failures)} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
