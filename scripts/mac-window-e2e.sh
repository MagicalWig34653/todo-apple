#!/bin/bash
# Isolated E2E of the REAL macOS app window (card A6B0D5E3, Glow-up W4). Nothing appears on the desktop and nothing is activated:
#  - native backend (Hauptrepo `.build/debug/App`) on a scratch SQLite DB, 127.0.0.1, own port; DATABASE_DRIVER=sqlite is ALWAYS set
#    (without it the backend would try the configured MySQL),
#  - seed via `LiveEtappe2Tests/testSeedDemoData` (TodoCore), real HTTP,
#  - the Debug Todo.app executable is started directly (no LaunchServices, no `open`) with `TODO_DEBUG_WINDOW_SHOTS=<dir>`:
#    activation policy .prohibited, a real NSWindow with NSHostingController, sidebar rows selected through the real AppKit
#    outline view, window never ordered front; PNGs of light/dark per screen plus report.json,
#  - `scripts/verify-mac-window.py` checks the claims.
# Usage: scripts/mac-window-e2e.sh [app-executable]   env: TODO_MAIN_REPO, E2E_PORT, TODO_WINDOW_OUT, KEEP=1
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH
MAIN="${TODO_MAIN_REPO:-/Users/linolaske/Documents/Code Projekte/PhpstormProjects/todo}"
BACKEND="$MAIN/.build/debug/App"
APP="${1:-${TODO_MAC_APP:-}}"
[ -x "$APP" ] || { echo "usage: $0 <path to Todo.app/Contents/MacOS/Todo> (Debug build)"; exit 2; }
# Safety: a build without the window-shots mode would open a normal window on the desktop. Refuse to start it then.
grep -aq "TODO_DEBUG_WINDOW_SHOTS" "$APP" "${APP%/*}"/*.dylib || { echo "FAIL: this app build has no TODO_DEBUG_WINDOW_SHOTS mode; not started (would show a window)"; exit 4; }
PORT="${E2E_PORT:-28931}"
ORIGIN="http://127.0.0.1:$PORT"
WORK="$(mktemp -d /private/tmp/todo-mac-window.XXXXXX)"
OUT="${TODO_WINDOW_OUT:-$WORK/shots}"
mkdir -p "$OUT"
BACKEND_PID=""
cleanup() { [ -n "$BACKEND_PID" ] && kill "$BACKEND_PID" 2>/dev/null || true; [ "${KEEP:-0}" = 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

export DATABASE_DRIVER=sqlite DB_NAME="$WORK/e2e.sqlite" OAUTH_ISSUER="$ORIGIN" BOOTSTRAP_TOKEN=dev-bootstrap-only
SETTINGS_ENCRYPTION_KEY="$(head -c 32 /dev/urandom | base64)"; export SETTINGS_ENCRYPTION_KEY
"$BACKEND" migrate --yes >"$WORK/migrate.log" 2>&1
"$BACKEND" serve --env production --hostname 127.0.0.1 --port "$PORT" >"$WORK/backend.log" 2>&1 &
BACKEND_PID=$!
for _ in $(seq 1 60); do curl -fsS -o /dev/null "$ORIGIN/health/live" 2>/dev/null && break; sleep 1; done
curl -fsS -o /dev/null "$ORIGIN/health/live" || { echo "backend did not start"; tail -20 "$WORK/backend.log"; exit 1; }

(cd TodoCore && TODO_LIVE_BASE_URL="$ORIGIN" TODO_LIVE_SEED_OUT="$WORK/seed.json" TODO_LIVE_SEED_STATE=1 TODO_LIVE_SEED_FEED=1 TODO_LIVE_SEED_BOARD=1 \
  swift test --filter 'LiveEtappe2Tests/testSeedDemoData' >"$WORK/seed.log" 2>&1) || { echo "seed failed"; tail -20 "$WORK/seed.log"; exit 1; }
TOKEN="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["token"])' "$WORK/seed.json")"

env TODO_DEBUG_SERVER="$ORIGIN" TODO_DEBUG_TOKEN="$TOKEN" TODO_DEBUG_WINDOW_SHOTS="$OUT" "$APP" >"$WORK/app.log" 2>&1 \
  || { echo "app exited with $?"; tail -20 "$WORK/app.log"; exit 1; }
python3 -I scripts/verify-mac-window.py "$OUT"
echo "shots: $OUT"
