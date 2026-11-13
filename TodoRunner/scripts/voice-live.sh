#!/bin/bash
# Live voice test against a native todolino backend with a scratch SQLite database (no Docker, no mocks).
# Usage: TODO_BACKEND_BIN=/path/to/App [RUNNER_VOICE_MODEL_FOLDER=/path/to/whisperkit/model] scripts/voice-live.sh
set -u
bin="${TODO_BACKEND_BIN:?path of the backend binary (swift build product App)}"
scratch="$(mktemp -d /private/tmp/claude-501/voice-live.XXXXXX)"
port="${PORT:-28741}"
export DATABASE_DRIVER=sqlite DB_NAME="$scratch/live.sqlite" RP_ID=localhost RP_ORIGIN="http://localhost:$port" BOOTSTRAP_TOKEN=live-bootstrap-only
"$bin" migrate --yes >/dev/null 2>&1
"$bin" serve --hostname 127.0.0.1 --port "$port" >"$scratch/backend.log" 2>&1 & pid=$!
cleanup() { kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; rm -rf "$scratch"; }
trap cleanup EXIT
for _ in $(seq 1 60); do curl -sf "http://127.0.0.1:$port/health" >/dev/null 2>&1 && break; sleep 0.5; done
cd "$(dirname "$0")/.."
runner=(swift test --filter VoiceLiveTests)
if [ "${NET_LOOPBACK_ONLY:-0}" = 1 ]; then
  # Network proof: after a normal build, the whole test process (engines included) runs in a macOS sandbox that only allows
  # connections to loopback. A download or any other outbound connection would fail the run.
  swift build --build-tests >/dev/null 2>&1
  runner=(sandbox-exec -p '(version 1)(allow default)(deny network-outbound (remote ip))(allow network-outbound (remote ip "localhost:*"))' swift test --disable-sandbox --skip-build --filter VoiceLiveTests)
fi
RUNNER_VOICE_LIVE=1 RUNNER_LIVE_BASE_URL="http://127.0.0.1:$port" RUNNER_LIVE_BOOTSTRAP_TOKEN=live-bootstrap-only \
  RUNNER_LIVE_RP_ORIGIN="http://localhost:$port" "${runner[@]}"
code=$?
if grep -qE "Live Testsatz|Wie steht es" "$scratch/backend.log"; then echo "FAIL: transcript in backend log"; code=1; fi
exit $code
