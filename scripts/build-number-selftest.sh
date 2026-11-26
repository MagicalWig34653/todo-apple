#!/usr/bin/env bash
# Self-test for the build number counter: scripts/build-number.sh and the two TestFlight scripts that use it. Runs the
# real scripts in a throw-away git repository; xcodegen and xcodebuild are stubs (TODO_XCODEGEN, TODO_XCODEBUILD), nothing
# is built, signed or uploaded.
# Usage: scripts/build-number-selftest.sh
set -uo pipefail
src="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"; fails=0
trap 'rm -rf "$work"' EXIT
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
repo="$work/repo"; config="$repo/App/Config/Base.xcconfig"
mkdir -p "$repo/scripts" "$repo/App/Config" "$work/bin"
cp "$src"/scripts/testflight-archive*.sh "$repo/scripts/"
[[ -f "$src/scripts/build-number.sh" ]] && cp "$src/scripts/build-number.sh" "$repo/scripts/"
cp "$src/ExportOptions.plist" "$repo/"
printf 'MARKETING_VERSION = 0.1.1\nCURRENT_PROJECT_VERSION = 23\nOTHER = 1\n' >"$config"
echo untouched >"$repo/other.txt"
git -C "$repo" init -q && git -C "$repo" config user.email selftest@example.invalid && git -C "$repo" config user.name selftest
git -C "$repo" add -A && git -C "$repo" commit -qm start
printf '#!/usr/bin/env bash\nexit 0\n' >"$work/bin/xcodegen"
printf '#!/usr/bin/env bash\necho "xcodebuild $*" >>"$STUB_LOG"\nexit ${STUB_EXIT:-0}\n' >"$work/bin/xcodebuild"
chmod +x "$work"/bin/*
export TODO_XCODEGEN="$work/bin/xcodegen" TODO_XCODEBUILD="$work/bin/xcodebuild" STUB_LOG="$work/calls.log" TODO_OUT_DIR="$work/out" TODO_TEAM_ID=TEAM
unset TODO_BUILD_NUMBER TODO_UPLOAD TODO_ARCHIVE_ONLY TODO_UNSIGNED TODO_VERSION TODO_BUNDLE_PREFIX

number() { sed -n 's/^CURRENT_PROJECT_VERSION = //p' "$config"; }
commits() { git -C "$repo" rev-list --count HEAD; }
clean() { [[ -z "$(git -C "$repo" status --porcelain)" ]]; }
run() { : >"$STUB_LOG"; (cd "$work" && env "$@") >"$work/out.log" 2>&1; code=$?; }
archived_with() { grep -q "^xcodebuild archive .*CURRENT_PROJECT_VERSION=$1\( \|$\)" "$STUB_LOG"; }

run "$repo/scripts/build-number.sh" current
check "current: prints 23 and changes nothing" '[[ $code -eq 0 && "$(cat "$work/out.log")" == 23 && $(commits) -eq 1 ]]'

run "$repo/scripts/testflight-archive.sh"
check "dry run: archives with the current number 23" '[[ $code -eq 0 ]] && archived_with 23'
check "dry run: no new commit" '[[ $(commits) -eq 1 && $(number) == 23 ]] && clean'

run TODO_UNSIGNED=1 "$repo/scripts/testflight-archive.sh"
check "unsigned: current number, no new commit" '[[ $code -eq 0 && $(commits) -eq 1 ]] && archived_with 23'

echo staged >"$repo/other.txt"; git -C "$repo" add other.txt
run TODO_UPLOAD=1 "$repo/scripts/testflight-archive.sh"
check "iOS upload: archives with the next number 24" '[[ $code -eq 0 ]] && archived_with 24'
check "iOS upload: counter stored" '[[ $(number) == 24 ]]'
check "iOS upload: exactly one commit with only the config" '[[ $(commits) -eq 2 && "$(git -C "$repo" show --name-only --format= HEAD)" == App/Config/Base.xcconfig ]]'
check "iOS upload: commit names the number" 'git -C "$repo" log -1 --format=%s | grep -q "Buildnummer 24"'
check "iOS upload: other settings untouched" 'grep -qx "MARKETING_VERSION = 0.1.1" "$config" && grep -qx "OTHER = 1" "$config"'
check "iOS upload: other staged work stays staged" '[[ "$(git -C "$repo" diff --cached --name-only)" == other.txt ]]'
check "iOS upload: export ran" 'grep -q "^xcodebuild -exportArchive" "$STUB_LOG"'
git -C "$repo" commit -qm other

run TODO_BUILD_NUMBER=24 TODO_ARCHIVE_ONLY=1 "$repo/scripts/testflight-archive-mac.sh"
check "Mac with the same number: archives with 24" '[[ $code -eq 0 ]] && archived_with 24'
check "Mac with the same number: no new commit" '[[ $(commits) -eq 3 && $(number) == 24 ]] && clean'

run TODO_ARCHIVE_ONLY=1 "$repo/scripts/testflight-archive.sh"
check "iOS archive for the upload gate: reserves 25" '[[ $code -eq 0 && $(number) == 25 && $(commits) -eq 4 ]] && archived_with 25'
check "iOS archive for the upload gate: no export" '! grep -q -- "-exportArchive" "$STUB_LOG"'

run TODO_UPLOAD=1 "$repo/scripts/testflight-archive-mac.sh"
check "Mac upload: reserves 26" '[[ $code -eq 0 && $(number) == 26 ]] && archived_with 26'

run STUB_EXIT=65 TODO_UPLOAD=1 "$repo/scripts/testflight-archive.sh"
check "failed archive: exit passed on, number stays used" '[[ $code -ne 0 && $(number) == 27 ]] && clean'

before=$(commits)
run TODO_BUILD_NUMBER=2611251650 TODO_UPLOAD=1 "$repo/scripts/testflight-archive.sh"
check "number above the counter: refused before xcodebuild" '[[ $code -ne 0 && ! -s "$STUB_LOG" && $(commits) -eq $before ]]'
run TODO_BUILD_NUMBER=abc TODO_UPLOAD=1 "$repo/scripts/testflight-archive.sh"
check "number that is no number: refused" '[[ $code -ne 0 && ! -s "$STUB_LOG" ]]'

echo "# local edit" >>"$config"
run TODO_UPLOAD=1 "$repo/scripts/testflight-archive.sh"
check "uncommitted config: refused, counter and edit kept" '[[ $code -ne 0 && ! -s "$STUB_LOG" && $(number) == 27 && $(commits) -eq $before ]] && grep -q "# local edit" "$config"'
git -C "$repo" checkout -q App/Config/Base.xcconfig

sed -i '' 's/^CURRENT_PROJECT_VERSION = .*/CURRENT_PROJECT_VERSION = $(OTHER)/' "$config"; git -C "$repo" commit -qam broken
run TODO_UPLOAD=1 "$repo/scripts/testflight-archive.sh"
check "counter that is no number: refused" '[[ $code -ne 0 && ! -s "$STUB_LOG" ]]'

run grep -rnE 'date \+%' "$src/scripts" --include='testflight*' --include=build-number.sh
check "no date build number in the scripts" '[[ $code -eq 1 ]]'
check "repository counter is a short running number" '[[ "$(sed -n "s/^CURRENT_PROJECT_VERSION = //p" "$src/App/Config/Base.xcconfig")" -ge 23 ]] && [[ "$(sed -n "s/^CURRENT_PROJECT_VERSION = //p" "$src/App/Config/Base.xcconfig")" -lt 100000 ]]'
check "repository version is at least 0.1.1" 'grep -qx "MARKETING_VERSION = 0\.1\.[1-9][0-9]*" "$src/App/Config/Base.xcconfig"'
[[ $fails -eq 0 ]] && echo "selftest: all passed" || { echo "selftest: $fails failed"; exit 1; }
