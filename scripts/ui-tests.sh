#!/usr/bin/env bash
# One command for the iOS UI tests (merge checks): starts a local Todolino test backend (native build, scratch SQLite) on
# 127.0.0.1:28080, seeds demo data through the TodoCore live test (token via TODO_LIVE_SEED_OUT), runs the Todo-iOS-UITests
# on a throw-away simulator (headless, no Simulator window) and always cleans up (trap): backend, simulator, scratch.
# Usage: scripts/ui-tests.sh [extra xcodebuild args, e.g. -only-testing:Todo-iOS-UITests/TodoUITests]
# Exit code: that of xcodebuild (0 = all green); 2 = setup problem (port taken, backend binary missing).
# Env (all optional):
#   TODO_BACKEND_BIN   backend binary; default <mainRepo>/.build/debug/App, mainRepo from .workspace.local.json
#   TODO_UITEST_PORT   default 28080 (the app's default server); a taken port is refused, never killed
#   TODO_UITEST_SEEDS  space-separated TODO_LIVE_SEED_* switches, default "FEED STATE BOARD W3" (all set to 1)
#   TODO_UITEST_RUNTIME simulator runtime id, default com.apple.CoreSimulator.SimRuntime.iOS-27-0
#   TODO_UITEST_DEVICE  existing simulator UDID to use instead of a throw-away one (it is left alone afterwards)
#   TODO_UITEST_ALL=1  also run the two local helpers AuditTimesServerE2E and ReviewVariantsServerE2E; they need their own seed
#                      (LiveReviewVariantsTests.testSeedVariantReviews) and are skipped by default
#   TODO_UITEST_RETRIES failed tests are repeated up to this many times (default 1; accessibility audits and lazy stacks
#                      flake once in a while); a test that passed on a retry is still reported as such by xcodebuild
#   TODO_UITEST_TMP    scratch directory (default mktemp); TODO_UITEST_KEEP=1 keeps it
set -euo pipefail
cd "$(dirname "$0")/.."
port="${TODO_UITEST_PORT:-28080}"
base="http://127.0.0.1:$port"
runtime="${TODO_UITEST_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-27-0}"
scratch="${TODO_UITEST_TMP:-$(mktemp -d)}"
backend_pid="" sim_created=""

die() { echo "ui-tests: $*" >&2; exit 2; }
cleanup() {
  local code=$?
  [[ -n "$backend_pid" ]] && kill "$backend_pid" 2>/dev/null && wait "$backend_pid" 2>/dev/null || true
  if [[ -n "$sim_created" ]]; then xcrun simctl shutdown "$sim_created" >/dev/null 2>&1 || true; xcrun simctl delete "$sim_created" >/dev/null 2>&1 || true; fi
  [[ "${TODO_UITEST_KEEP:-0}" == "1" ]] && echo "ui-tests: scratch kept at $scratch" || rm -rf "$scratch"
  exit $code
}
trap cleanup EXIT INT TERM

nc -z 127.0.0.1 "$port" 2>/dev/null && die "port $port is already in use (another backend running?); stop it or set TODO_UITEST_PORT"

# Backend binary: env, else the main repository named in .workspace.local.json (repo root or the main worktree's root).
bin="${TODO_BACKEND_BIN:-}"
if [[ -z "$bin" ]]; then
  for dir in "$PWD" "$(cd "$(git rev-parse --git-common-dir)/.." && pwd)"; do
    [[ -f "$dir/.workspace.local.json" ]] || continue
    main="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["mainRepo"])' "$dir/.workspace.local.json")"
    bin="$main/.build/debug/App"; break
  done
fi
[[ -x "$bin" ]] || die "backend binary not found (${bin:-no .workspace.local.json}); build it in the main repo (swift build) or set TODO_BACKEND_BIN"

mkdir -p "$scratch"
export DATABASE_DRIVER=sqlite DB_NAME="$scratch/ui.sqlite" RP_ID=localhost RP_ORIGIN="http://localhost:$port" OAUTH_ISSUER="$base" BOOTSTRAP_TOKEN=dev-bootstrap-only
"$bin" migrate --yes >"$scratch/migrate.log" 2>&1 || { cat "$scratch/migrate.log" >&2; die "migrate failed"; }
"$bin" serve --hostname 127.0.0.1 --port "$port" >"$scratch/backend.log" 2>&1 & backend_pid=$!
for _ in $(seq 1 60); do curl -fs "$base/health/ready" >/dev/null 2>&1 && break; kill -0 "$backend_pid" 2>/dev/null || { cat "$scratch/backend.log" >&2; die "backend exited"; }; sleep 1; done
curl -fs "$base/health/ready" >/dev/null 2>&1 || die "backend not ready after 60 s (log: $scratch/backend.log)"
echo "ui-tests: backend up on $base ($bin)"

# Seed: virtual-passkey registration of "Alice" + demo data; the session token lands in seed.json.
seeds=(); for s in ${TODO_UITEST_SEEDS:-FEED STATE BOARD W3}; do seeds+=("TODO_LIVE_SEED_$s=1"); done
env TODO_LIVE_BASE_URL="$base" TODO_LIVE_RP_ORIGIN="$RP_ORIGIN" TODO_LIVE_SEED_OUT="$scratch/seed.json" "${seeds[@]}" \
  swift test --package-path TodoCore --filter LiveEtappe2Tests/testSeedDemoData >"$scratch/seed.log" 2>&1 \
  || { tail -30 "$scratch/seed.log" >&2; die "seeding failed"; }
token="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["token"])' "$scratch/seed.json")"

sim="${TODO_UITEST_DEVICE:-}"
if [[ -z "$sim" ]]; then
  sim="$(xcrun simctl create "todo-uitest-$$" "iPhone 18 Pro" "$runtime")"; sim_created="$sim"
fi

xcodegen generate >/dev/null
echo "ui-tests: running Todo-iOS-UITests on simulator $sim"
skip=(-skip-testing:Todo-iOS-UITests/AuditTimesServerE2E -skip-testing:Todo-iOS-UITests/ReviewVariantsServerE2E)
[[ "${TODO_UITEST_ALL:-0}" == "1" ]] && skip=()
set +e
TEST_RUNNER_TODO_UITEST_SERVER="$base" TEST_RUNNER_TODO_UITEST_TOKEN="$token" \
  xcodebuild test -project Todo.xcodeproj -scheme Todo-iOS -destination "id=$sim" \
  -resultBundlePath "$scratch/result.xcresult" -retry-tests-on-failure -test-iterations $(( ${TODO_UITEST_RETRIES:-1} + 1 )) CODE_SIGNING_ALLOWED=NO ${skip[@]+"${skip[@]}"} "$@"
code=$?
set -e
# Summary line (the number to quote in progress notes).
if [[ -d "$scratch/result.xcresult" ]]; then
  xcrun xcresulttool get test-results summary --path "$scratch/result.xcresult" --format json 2>/dev/null \
    | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print("ui-tests: %s tests, %s passed, %s failed, %s skipped" % tuple(d.get(k,"?") for k in ("totalTestCount","passedTests","failedTests","skippedTests")))' || true
fi
echo "ui-tests: exit $code"
exit $code
