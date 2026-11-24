#!/usr/bin/env bash
# Self-test for scripts/ui-tests.sh without simulator or real backend (stub App binary and stubbed tools in PATH).
# Case 1: port already taken -> refuses, exit != 0, the foreign listener is untouched.
# Case 2: test run fails -> exit code is passed on, backend stopped, scratch directory and simulator removed.
# Usage: scripts/ui-tests-selftest.sh
set -uo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d)"; port=28979; fails=0
trap 'kill ${holder:-} 2>/dev/null; rm -rf "$work"' EXIT
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

mkdir -p "$work/bin"
# Stub backend: migrate does nothing, serve answers every request with 200.
cat >"$work/App" <<'S'
#!/usr/bin/env bash
[[ "$1" == migrate ]] && exit 0
exec python3 -I -c "
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(s): s.send_response(200); s.end_headers(); s.wfile.write(b'ok')
    def log_message(*a): pass
http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()" "$(printf '%s\n' "$@" | sed -n '/^--port$/{n;p;}')"
S
chmod +x "$work/App"
# Stubbed tools: log calls; xcodebuild fails like a red test run; the seed step (swift test) succeeds and writes a token.
for t in xcodegen xcrun; do printf '#!/usr/bin/env bash\necho "%s $*" >>"$STUB_LOG"\n[[ "%s" == xcrun && "$2" == create ]] && echo STUB-SIM\nexit 0\n' "$t" "$t" >"$work/bin/$t"; done
printf '#!/usr/bin/env bash\necho "swift $*" >>"$STUB_LOG"\necho "{\\"token\\":\\"stub-token\\"}" >"$TODO_LIVE_SEED_OUT"\n' >"$work/bin/swift"
printf '#!/usr/bin/env bash\necho "xcodebuild $* server=$TEST_RUNNER_TODO_UITEST_SERVER token=$TEST_RUNNER_TODO_UITEST_TOKEN" >>"$STUB_LOG"\nexit 7\n' >"$work/bin/xcodebuild"
chmod +x "$work"/bin/*

export TODO_BACKEND_BIN="$work/App" TODO_UITEST_PORT=$port STUB_LOG="$work/calls.log" TODO_UITEST_TMP="$work/scratch"

python3 -I -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1 & holder=$!
sleep 1
PATH="$work/bin:$PATH" scripts/ui-tests.sh >"$work/out1" 2>&1; code=$?
check "port busy: exit != 0" '[[ $code -ne 0 ]]'
check "port busy: message names the port" 'grep -q "$port" "$work/out1"'
check "port busy: foreign listener still alive" 'kill -0 $holder 2>/dev/null'
kill $holder; wait $holder 2>/dev/null; holder=

PATH="$work/bin:$PATH" scripts/ui-tests.sh >"$work/out2" 2>&1; code=$?
check "failing run: exit code 7 passed on" '[[ $code -eq 7 ]]'
check "failing run: xcodebuild got server and token" 'grep -q "server=http://127.0.0.1:$port token=stub-token" "$work/calls.log"'
check "failing run: seed ran with the feed seed" 'grep -q "LiveEtappe2Tests/testSeedDemoData" "$work/calls.log"'
check "failing run: port free again" '! python3 -I -c "import socket;s=socket.socket();s.settimeout(1);s.connect((\"127.0.0.1\",$port))" 2>/dev/null'
check "failing run: scratch removed" '[[ ! -e "$work/scratch" ]]'
check "failing run: simulator deleted" 'grep -q "xcrun simctl delete STUB-SIM" "$work/calls.log"'
[[ $fails -eq 0 ]] && echo "selftest: all passed" || { echo "selftest: $fails failed"; exit 1; }
