#!/usr/bin/env python3
"""Checks the output of the isolated macOS window run (`scripts/mac-window-e2e.sh`, card A6B0D5E3).

Usage: python3 -I scripts/verify-mac-window.py <dir with report.json and PNGs>
Exit 0 only if every claim holds; each failure is printed. No third-party modules (PNG decoded with zlib).
"""
import json, struct, sys, zlib, os

EXPECTED = ["feed", "commandcenter", "today", "upcoming", "inbox", "calendar", "project", "task", "account"]
fails = []

def fail(msg):
    fails.append(msg)
    print("FAIL:", msg)

def read_png(path):
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos, idat, w, h, depth, ctype = 8, b"", 0, 0, 8, 6
    while pos < len(data):
        n, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if kind == b"IHDR":
            w, h, depth, ctype = struct.unpack(">IIBB", body[:10])
        elif kind == b"IDAT":
            idat += body
        pos += 12 + n
    channels = {2: 3, 6: 4, 0: 1, 4: 2}[ctype]
    raw, bpp, stride = zlib.decompress(idat), channels * (depth // 8), w * channels * (depth // 8)
    rows, prev = [], bytearray(stride)
    for y in range(h):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line); prev = line
    return w, h, channels, rows

def luminance(rows, channels, w, h, step=16):
    total, n = 0, 0
    for y in range(0, h, step):
        for x in range(0, w, step):
            px = rows[y][x * channels:x * channels + 3]
            total += (px[0] * 299 + px[1] * 587 + px[2] * 114) / 1000; n += 1
    return total / max(n, 1)

def main(out):
    path = os.path.join(out, "report.json")
    if not os.path.exists(path):
        fail("report.json missing (the app wrote no window report)")
        return
    report = json.load(open(path))
    env = report.get("environment", {})
    # Isolation: nothing was shown to the user and nothing was activated.
    if env.get("activationPolicy") != "prohibited": fail(f"activation policy is {env.get('activationPolicy')}, expected prohibited")
    if env.get("appActive") is not False: fail("app reported active")
    if env.get("windowOnScreen") is not False: fail("window reported on screen")
    if env.get("windowClass") != "NSWindow" or not env.get("hostingController"): fail("not a real AppKit window with a hosting controller")
    control = report.get("control", {})
    def near_black(h): return h is not None and all(int(h[i:i + 2], 16) < 24 for i in (1, 3, 5))
    # A plain SwiftUI sidebar List in the same offscreen harness: if ITS selected row is black too, black is a capture artefact of
    # the never-key window and not an app styling bug; then the check below only requires that AppKit reports the right row selected.
    if not control: fail("no control probe in report")
    shots = {(s["screen"], s["scheme"]): s for s in report.get("shots", [])}
    for screen in EXPECTED:
        lums = {}
        for scheme in ("light", "dark"):
            s = shots.get((screen, scheme))
            if not s: fail(f"no shot for {screen}/{scheme}"); continue
            file = os.path.join(out, s["file"])
            if not os.path.exists(file): fail(f"{s['file']} missing"); continue
            try: w, h, ch, rows = read_png(file)
            except Exception as e: fail(f"{s['file']} unreadable: {e}"); continue
            if w < 2000 or h < 1200: fail(f"{s['file']} too small: {w}x{h}")
            lums[scheme] = luminance(rows, ch, w, h)
            if len({bytes(r[i:i + 12]) for r in rows[::25] for i in range(0, len(r) - 12, 600)}) < 8: fail(f"{s['file']} looks empty")
            if not s.get("selectionOK"): fail(f"{screen}/{scheme}: model selection is {s.get('modelSelection')} after the click path")
            if s.get("clickPath") and s.get("selectedRowIndex", -1) < 0: fail(f"{screen}/{scheme}: no sidebar row selected in the outline view")
            artefact = near_black(control.get(scheme))
            if s.get("clickPath") and not s.get("sidebarSelectionLegible") and not artefact: fail(f"{screen}/{scheme}: selected sidebar row not legible (colour {s.get('selectionColor')}, label {s.get('selectionLabelColor')})")
        if len(lums) == 2 and not lums["dark"] < lums["light"] - 40:
            fail(f"{screen}: dark ({lums['dark']:.0f}) is not clearly darker than light ({lums['light']:.0f})")
    # The empty chat field of the task column is one line high and shows its placeholder (28.11.2026: about five lines).
    for scheme in ("light", "dark"):
        fields = (shots.get(("task", scheme)) or {}).get("textFields", [])
        composer = [f for f in fields if f["placeholder"] == "Nachricht schreiben"]
        if not composer: fail(f"task/{scheme}: no chat field with placeholder 'Nachricht schreiben' in {fields}")
        elif composer[0]["height"] > 30: fail(f"task/{scheme}: chat field is {composer[0]['height']:.0f} pt high, expected one line: {composer[0]}")
    if not fails:
        print(f"OK: {len(shots)} shots, real window never on screen, policy prohibited")

main(sys.argv[1])
sys.exit(1 if fails else 0)
