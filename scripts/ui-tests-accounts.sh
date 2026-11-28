#!/usr/bin/env bash
# End-to-end account switch (card 346B7A6F, App/UITests/AccountSwitchUITests.swift): two native backends with scratch
# SQLite (A with two accounts behind scripts/selection-proxy.py, B with a third one), password login, a throw-away
# simulator per look. The build is signed ad hoc ("run locally"): without it the simulator keychain refuses to store the
# session token and nobody can sign in. Ends only what it started.
# Usage: scripts/ui-tests-accounts.sh [extra xcodebuild args]
# Env (optional):
#   TODO_BACKEND_BIN    backend binary; default <mainRepo>/.build/debug/App from .workspace.local.json of the main checkout
#   TODO_ACCOUNTS_OUT   directory for pictures (<out>/bilder) and logs (<out>/tests); default a kept scratch directory
#   TODO_ACCOUNTS_LOOKS default "hell dunkel"
#   TODO_ACCOUNTS_PORT  backend A, default 28961; the proxy takes the next port, backend B the one after; a taken port is refused
set -euo pipefail
cd "$(dirname "$0")/.."
port="${TODO_ACCOUNTS_PORT:-28961}"
proxy_port=$((port + 1)) second_port=$((port + 2))
base="http://127.0.0.1:$port" second="http://127.0.0.1:$second_port"
scratch="$(mktemp -d)"
out="${TODO_ACCOUNTS_OUT:-$scratch/out}"
backend_pid="" second_pid="" proxy_pid="" sim=""

die() { echo "ui-tests-accounts: $*" >&2; exit 2; }
stop() { [[ -n "$1" ]] && kill "$1" 2>/dev/null && wait "$1" 2>/dev/null || true; }
stop_all() { stop "$proxy_pid"; stop "$backend_pid"; stop "$second_pid"; proxy_pid="" backend_pid="" second_pid=""; }
drop_sim() { if [[ -n "$sim" ]]; then xcrun simctl shutdown "$sim" >/dev/null 2>&1 || true; xcrun simctl delete "$sim" >/dev/null 2>&1 || true; sim=""; fi; }
cleanup() {
  local code=$?
  stop_all; drop_sim
  [[ -n "${TODO_ACCOUNTS_OUT:-}" ]] && rm -rf "$scratch" || echo "ui-tests-accounts: output in $out"
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

# serve <name> <port> <log suffix>: migrates a fresh database and starts the backend; prints nothing, sets $served.
serve() {
  local db="$scratch/$1.sqlite" p="$2"
  nc -z 127.0.0.1 "$p" 2>/dev/null && die "port $p is already in use"
  local envs=(DATABASE_DRIVER=sqlite DB_NAME="$db" RP_ID=localhost RP_ORIGIN="http://localhost:$p" OAUTH_ISSUER="http://127.0.0.1:$p" BOOTSTRAP_TOKEN=dev-bootstrap-only PASSWORD_LOGIN_ENABLED=true)
  env "${envs[@]}" "$bin" migrate --yes >"$out/tests/migrate-$1.log" 2>&1 || die "migrate failed ($1)"
  env "${envs[@]}" "$bin" serve --hostname 127.0.0.1 --port "$p" >"$out/tests/backend-$1.log" 2>&1 & served=$!
  for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$p/health/ready" >/dev/null 2>&1 && return 0; kill -0 "$served" 2>/dev/null || die "backend $1 exited"; sleep 1; done
  die "backend $1 not ready"
}

xcodegen generate >/dev/null
status=0
for look in ${TODO_ACCOUNTS_LOOKS:-hell dunkel}; do
  stop_all; drop_sim
  nc -z 127.0.0.1 "$proxy_port" 2>/dev/null && die "port $proxy_port is already in use"
  serve "a-$look" "$port"; backend_pid=$served
  serve "b-$look" "$second_port"; second_pid=$served
  env TODO_LIVE_BASE_URL="$base" TODO_LIVE_RP_ORIGIN="http://localhost:$port" TODO_LIVE_SECOND_URL="$second" \
    TODO_LIVE_SECOND_RP_ORIGIN="http://localhost:$second_port" TODO_LIVE_ACCOUNTS_OUT="$scratch/accounts-$look.json" \
    swift test --package-path TodoCore --filter LiveAccountSwitchSeed >"$out/tests/seed-$look.log" 2>&1 || die "seeding failed (see $out/tests/seed-$look.log)"
  [[ -s "$scratch/accounts-$look.json" ]] || die "seed wrote nothing"
  python3 -I scripts/selection-proxy.py "$proxy_port" "$port" >"$out/tests/proxy-$look.log" 2>&1 & proxy_pid=$!
  sleep 1
  kill -0 "$proxy_pid" 2>/dev/null || die "proxy exited"
  # A fresh simulator per look: the notification permission and the keychain are part of what is tested.
  sim="$(xcrun simctl create "todo-accounts-$$-$look" "iPhone 18 Pro" com.apple.CoreSimulator.SimRuntime.iOS-27-0)"
  # The look is the system appearance of the simulator (the app follows it, also after its own reset on sign-out).
  xcrun simctl boot "$sim" >/dev/null 2>&1 || true
  xcrun simctl ui "$sim" appearance "$([[ $look == dunkel ]] && echo dark || echo light)"
  set +e
  TEST_RUNNER_TODO_ACCOUNTS_PROXY="http://127.0.0.1:$proxy_port" TEST_RUNNER_TODO_ACCOUNTS_BACKEND="$base" \
    TEST_RUNNER_TODO_ACCOUNTS_SECOND="$second" TEST_RUNNER_TODO_ACCOUNTS_JSON="$(cat "$scratch/accounts-$look.json")" \
    TEST_RUNNER_TODO_TOUR_OUT="$(cd "$out/bilder" && pwd)" TEST_RUNNER_TODO_PROOF_LOOK="$look" \
    xcodebuild test -project Todo.xcodeproj -scheme Todo-iOS -destination "id=$sim" -derivedDataPath "${TODO_ACCOUNTS_DD:-$scratch/dd}" \
    -collect-test-diagnostics never CODE_SIGN_IDENTITY=- -only-testing:Todo-iOS-UITests/AccountSwitchUITests "$@" \
    >"$out/tests/ui-accounts-$look.log" 2>&1
  code=$?
  set -e
  (( code == 0 )) || status=$code
  echo "ui-tests-accounts: $look xcodebuild exit $code"
  grep -E "Test Case .*(passed|failed|skipped)|Executed [0-9]+ test|TEST (SUCCEEDED|FAILED)|error: " "$out/tests/ui-accounts-$look.log" | tail -12 || true
done
exit $status
