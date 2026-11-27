#!/usr/bin/env bash
# UI test of the selection editor's pending states (App/UITests/SelectionPendingTests.swift): native backend with a scratch
# SQLite per look, seeded groups, behind scripts/selection-proxy.py, on a throw-away simulator. Ends only what it started.
# Usage: scripts/ui-tests-selection.sh [-only-testing:... or other xcodebuild args]
# Env (optional):
#   TODO_BACKEND_BIN    backend binary; default <mainRepo>/.build/debug/App from .workspace.local.json of the main checkout
#   TODO_SELECTION_OUT  directory for pictures (<out>/bilder) and logs (<out>/tests); default a kept scratch directory
#   TODO_SELECTION_LOOKS  default "hell dunkel"
#   TODO_SELECTION_PORT   backend port, default 28861; the proxy takes the next one; a taken port is refused
set -euo pipefail
cd "$(dirname "$0")/.."
port="${TODO_SELECTION_PORT:-28861}"
proxy_port=$((port + 1))
base="http://127.0.0.1:$port"
scratch="$(mktemp -d)"
out="${TODO_SELECTION_OUT:-$scratch/out}"
backend_pid="" proxy_pid="" sim=""

die() { echo "ui-tests-selection: $*" >&2; exit 2; }
stop() { [[ -n "$1" ]] && kill "$1" 2>/dev/null && wait "$1" 2>/dev/null || true; }
cleanup() {
  local code=$?
  stop "$proxy_pid"; stop "$backend_pid"
  if [[ -n "$sim" ]]; then xcrun simctl shutdown "$sim" >/dev/null 2>&1 || true; xcrun simctl delete "$sim" >/dev/null 2>&1 || true; fi
  [[ -n "${TODO_SELECTION_OUT:-}" ]] && rm -rf "$scratch" || echo "ui-tests-selection: output in $out"
  exit $code
}
trap cleanup EXIT INT TERM

bin="${TODO_BACKEND_BIN:-}"
if [[ -z "$bin" ]]; then
  dir="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)"
  [[ -f "$dir/.workspace.local.json" ]] && bin="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["mainRepo"])' "$dir/.workspace.local.json")/.build/debug/App"
fi
[[ -x "$bin" ]] || die "backend binary not found (${bin:-no .workspace.local.json}); set TODO_BACKEND_BIN"
mkdir -p "$out/bilder" "$out/tests"

xcodegen generate >/dev/null
sim="$(xcrun simctl create "todo-selection-$$" "iPhone 18 Pro" com.apple.CoreSimulator.SimRuntime.iOS-27-0)"
status=0
for look in ${TODO_SELECTION_LOOKS:-hell dunkel}; do
  stop "$proxy_pid"; stop "$backend_pid"; proxy_pid="" backend_pid=""
  for p in $port $proxy_port; do nc -z 127.0.0.1 "$p" 2>/dev/null && die "port $p is already in use"; done
  export DATABASE_DRIVER=sqlite DB_NAME="$scratch/$look.sqlite" RP_ID=localhost RP_ORIGIN="http://localhost:$port" OAUTH_ISSUER="$base" BOOTSTRAP_TOKEN=dev-bootstrap-only
  "$bin" migrate --yes >"$out/tests/migrate-$look.log" 2>&1 || die "migrate failed"
  "$bin" serve --hostname 127.0.0.1 --port "$port" >"$out/tests/backend-$look.log" 2>&1 & backend_pid=$!
  for _ in $(seq 1 60); do curl -fs "$base/health/ready" >/dev/null 2>&1 && break; kill -0 "$backend_pid" 2>/dev/null || die "backend exited"; sleep 1; done
  env TODO_LIVE_BASE_URL="$base" TODO_LIVE_RP_ORIGIN="$RP_ORIGIN" TODO_LIVE_SEED_GROUPS_OUT="$scratch/seed-$look.json" \
    swift test --package-path TodoCore --filter LiveProjectGroupsTests/testSeedGroupsTour >"$out/tests/seed-$look.log" 2>&1 || die "seeding failed"
  token="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["token"])' "$scratch/seed-$look.json")"
  python3 -I scripts/selection-proxy.py $proxy_port $port >"$out/tests/proxy-$look.log" 2>&1 & proxy_pid=$!
  sleep 1
  kill -0 "$proxy_pid" 2>/dev/null || die "proxy exited"
  set +e
  TEST_RUNNER_TODO_UITEST_PROXY="http://127.0.0.1:$proxy_port" TEST_RUNNER_TODO_UITEST_TOKEN="$token" \
    TEST_RUNNER_TODO_TOUR_OUT="$(cd "$out/bilder" && pwd)" TEST_RUNNER_TODO_PROOF_LOOK="$look" \
    xcodebuild test -project Todo.xcodeproj -scheme Todo-iOS -destination "id=$sim" -derivedDataPath "$scratch/dd" \
    -collect-test-diagnostics never CODE_SIGNING_ALLOWED=NO -only-testing:Todo-iOS-UITests/SelectionPendingTests "$@" \
    >"$out/tests/ui-selection-$look.log" 2>&1
  code=$?
  set -e
  (( code == 0 )) || status=$code
  echo "ui-tests-selection: $look xcodebuild exit $code"
  grep -E "Test Case .*(passed|failed|skipped)|Executed [0-9]+ test|TEST (SUCCEEDED|FAILED)|error: " "$out/tests/ui-selection-$look.log" | tail -24 || true
done
exit $status
