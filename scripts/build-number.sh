#!/usr/bin/env bash
# The running build number: CURRENT_PROJECT_VERSION in App/Config/Base.xcconfig is the last number handed out. One counter
# for iOS and macOS; a number is never taken from the date and never used for two different uploads of one platform.
#   current  print the last number
#   next     raise the counter by one, commit only Base.xcconfig, print the new number
#   pick     the number for an archive script, from its environment:
#              TODO_BUILD_NUMBER set                  that number, only if it was handed out already (second platform)
#              TODO_UPLOAD=1 or TODO_ARCHIVE_ONLY=1   next (this archive is meant for an upload)
#              otherwise, and with TODO_UNSIGNED=1    current
# A reserved number stays used when the build or upload fails. Push the counter commit with the upload.
set -euo pipefail
cd "$(dirname "$0")/.."
config=App/Config/Base.xcconfig

die() { echo "build-number: $*" >&2; exit 2; }
current() {
  local n; n="$(sed -n 's/^CURRENT_PROJECT_VERSION = \([0-9][0-9]*\)$/\1/p' "$config")"
  [[ -n "$n" ]] || die "no plain number in 'CURRENT_PROJECT_VERSION = <n>' in $config"
  echo "$n"
}
next() {
  git diff --quiet HEAD -- "$config" || die "$config has uncommitted changes; commit them first"
  local n; n="$(current)"; n=$((n + 1))
  sed -i '' "s/^CURRENT_PROJECT_VERSION = .*/CURRENT_PROJECT_VERSION = $n/" "$config"
  git commit -q -m "Buildnummer $n reserviert (scripts/build-number.sh)" -- "$config" || die "commit of build number $n failed"
  echo "$n"
}

case "${1:-}" in
  current) current ;;
  next) next ;;
  pick)
    if [[ -n "${TODO_BUILD_NUMBER:-}" ]]; then
      last="$(current)"
      [[ "$TODO_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || die "TODO_BUILD_NUMBER '$TODO_BUILD_NUMBER' is not a number"
      [[ "${TODO_UNSIGNED:-0}" == "1" ]] || (( TODO_BUILD_NUMBER <= last )) ||
        die "TODO_BUILD_NUMBER $TODO_BUILD_NUMBER was never handed out (counter: $last); leave it unset to reserve the next one"
      echo "$TODO_BUILD_NUMBER"
    elif [[ "${TODO_UNSIGNED:-0}" != "1" && ( "${TODO_UPLOAD:-0}" == "1" || "${TODO_ARCHIVE_ONLY:-0}" == "1" ) ]]; then next
    else current
    fi ;;
  *) die "usage: scripts/build-number.sh current|next|pick" ;;
esac
