#!/usr/bin/env python3
"""Host helper for UI tests that change the system text size while the app runs.

A UI test cannot change the preferred content size category itself (only a relaunch with a launch argument or the Settings
app can), and `xcrun simctl ui <udid> content_size` runs on the host. The test therefore asks this loopback server:

  GET /size/<category>                  set once, answer when simctl returned
  GET /burst/<c1>,<c2>,...[?gap=<ms>]   set one after the other without waiting for the app, answer when all are set
  GET /appearance/<light|dark>          set the interface style (used only by the screenshot runs)
  GET /shot/<name>                      framebuffer screenshot into <shots dir>/<name>.png (only with a shots dir): XCUITest
                                        screenshots of a rotated iPad come out as a cropped portrait buffer

Only the simulator UDID given on the command line is ever touched, and only these three simctl options. Headless: no
Simulator window is opened or activated.
Usage: python3 -I sim-text-size-helper.py <udid> <port> [<shots dir>]   (stop with SIGTERM; scripts/ui-tests.sh starts and stops it)
"""
import re
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

SIZES = {"extra-small", "small", "medium", "large", "extra-large", "extra-extra-large", "extra-extra-extra-large",
         "accessibility-medium", "accessibility-large", "accessibility-extra-large",
         "accessibility-extra-extra-large", "accessibility-extra-extra-extra-large"}
udid = sys.argv[1]
shots = sys.argv[3] if len(sys.argv) > 3 else None


def simctl(option: str, value: str) -> bool:
    return subprocess.run(["xcrun", "simctl", "ui", udid, option, value], capture_output=True).returncode == 0


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlparse(self.path)
        kind, _, rest = url.path.strip("/").partition("/")
        ok = False
        if kind == "size" and rest in SIZES:
            ok = simctl("content_size", rest)
        elif kind == "burst":
            sizes = rest.split(",")
            gap = int(parse_qs(url.query).get("gap", ["0"])[0]) / 1000
            if sizes and all(s in SIZES for s in sizes):
                ok = True
                for s in sizes:
                    ok = simctl("content_size", s) and ok
                    time.sleep(gap)
        elif kind == "appearance" and re.fullmatch(r"light|dark", rest):
            ok = simctl("appearance", rest)
        elif kind == "shot" and shots and re.fullmatch(r"[A-Za-z0-9_.-]+", rest):
            ok = subprocess.run(["xcrun", "simctl", "io", udid, "screenshot", f"{shots}/{rest}.png"], capture_output=True).returncode == 0
        self.send_response(200 if ok else 400)
        self.end_headers()
        self.wfile.write(b"ok" if ok else b"bad request")

    def log_message(self, *args):  # quiet
        pass


HTTPServer(("127.0.0.1", int(sys.argv[2])), Handler).serve_forever()
