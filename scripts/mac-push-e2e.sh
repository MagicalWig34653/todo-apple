#!/bin/bash
# E2E of push taps in the REAL macOS main window, invisible (card D97C4918; same harness as scripts/mac-window-e2e.sh:
# activation policy .prohibited, window never on screen, the Debug executable is started directly). Native backend on a
# scratch SQLite DB, demo seed, then every push kind goes through the real NotificationDelegate (no APNs) in light and
# dark; scripts/verify-mac-push.py checks where each one lands.
# Usage: scripts/mac-push-e2e.sh <Todo.app/Contents/MacOS/Todo (Debug)>   env: TODO_MAIN_REPO, E2E_PORT, TODO_WINDOW_OUT
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH
MAIN="${TODO_MAIN_REPO:-/Users/linolaske/Documents/Code Projekte/PhpstormProjects/todo}"
BACKEND="$MAIN/.build/debug/App"
APP="${1:-}"
[ -x "$APP" ] || { echo "usage: $0 <path to Todo.app/Contents/MacOS/Todo> (Debug build)"; exit 2; }
# Safety: a build without this mode would open a normal window on the desktop.
grep -aq "TODO_DEBUG_WINDOW_PUSHES" "$APP" "${APP%/*}"/*.dylib || { echo "FAIL: build has no TODO_DEBUG_WINDOW_PUSHES mode; not started"; exit 4; }
PORT="${E2E_PORT:-28941}"
ORIGIN="http://127.0.0.1:$PORT"
nc -z 127.0.0.1 "$PORT" 2>/dev/null && { echo "port $PORT is in use"; exit 2; }
WORK="$(mktemp -d /private/tmp/todo-mac-push.XXXXXX)"
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
  swift test --filter 'LiveEtappe2Tests/testSeedDemoData|testSeedConfirmationRequests' >"$WORK/seed.log" 2>&1) || { echo "seed failed"; tail -20 "$WORK/seed.log"; exit 1; }
TOKEN="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["token"])' "$WORK/seed.json")"

python3 -I scripts/verify-mac-push.py prepare "$ORIGIN" "$TOKEN" "$WORK/pushes.json" "$OUT/expected.json"
env TODO_DEBUG_SERVER="$ORIGIN" TODO_DEBUG_TOKEN="$TOKEN" TODO_DEBUG_WINDOW_SHOTS="$OUT" TODO_DEBUG_WINDOW_PUSHES="$WORK/pushes.json" "$APP" >"$WORK/app.log" 2>&1 \
  || { echo "app exited with $?"; tail -20 "$WORK/app.log"; exit 1; }
python3 -I scripts/verify-mac-push.py check "$OUT"
echo "shots: $OUT"
