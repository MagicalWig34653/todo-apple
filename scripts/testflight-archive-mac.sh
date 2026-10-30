#!/usr/bin/env bash
# Builds a signed macOS archive (Todo-macOS, de.linolaske.todo, Universal Purchase) and exports it. Uploads only with TODO_UPLOAD=1.
# Archiving with -allowProvisioningUpdates also registers the macOS App ID in the developer portal.
# Upload needs an App Store Connect macOS app record; do not set TODO_UPLOAD before it exists.
# Env:
#   TODO_TEAM_ID        Apple Developer Team ID (required unless TODO_UNSIGNED=1)
#   TODO_BUNDLE_PREFIX  optional, overrides bundle id prefix
#   TODO_BUILD_NUMBER   optional, overrides CURRENT_PROJECT_VERSION
#   TODO_VERSION        optional, overrides MARKETING_VERSION
#   TODO_OUT_DIR        output dir (default: ./build/testflight-mac); use a path outside Documents
#   TODO_UPLOAD=1       export with destination=upload
#   TODO_ARCHIVE_ONLY=1 stop after the signed archive (registers the App ID, no export)
#   TODO_UNSIGNED=1     archive only with CODE_SIGNING_ALLOWED=NO
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${TODO_OUT_DIR:-$PWD/build/testflight-mac}"
ARCHIVE="$OUT/Todo-macOS.xcarchive"
mkdir -p "$OUT"

xcodegen generate

args=(-project Todo.xcodeproj -scheme Todo-macOS -configuration Release
      -destination 'generic/platform=macOS' -archivePath "$ARCHIVE"
      -derivedDataPath "$OUT/DerivedData")
[[ -n "${TODO_BUNDLE_PREFIX:-}" ]] && args+=("TODO_BUNDLE_ID_PREFIX=$TODO_BUNDLE_PREFIX")
[[ -n "${TODO_BUILD_NUMBER:-}" ]] && args+=("CURRENT_PROJECT_VERSION=$TODO_BUILD_NUMBER")
[[ -n "${TODO_VERSION:-}" ]] && args+=("MARKETING_VERSION=$TODO_VERSION")

if [[ "${TODO_UNSIGNED:-0}" == "1" ]]; then
  xcodebuild archive "${args[@]}" CODE_SIGNING_ALLOWED=NO
  echo "Unsigned archive: $ARCHIVE (not exportable)"
  exit 0
fi

: "${TODO_TEAM_ID:?Set TODO_TEAM_ID to your Apple Developer Team ID}"
xcodebuild archive "${args[@]}" DEVELOPMENT_TEAM="$TODO_TEAM_ID" -allowProvisioningUpdates
if [[ "${TODO_ARCHIVE_ONLY:-0}" == "1" ]]; then echo "Signed archive: $ARCHIVE"; exit 0; fi

EXPORT_PLIST="$OUT/ExportOptions.plist"
sed "s/TEAM_ID_PLACEHOLDER/$TODO_TEAM_ID/" ExportOptions.plist > "$EXPORT_PLIST"
if [[ "${TODO_UPLOAD:-0}" == "1" ]]; then
  /usr/libexec/PlistBuddy -c "Set :destination upload" "$EXPORT_PLIST"
fi
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$EXPORT_PLIST" \
  -exportPath "$OUT/export" -allowProvisioningUpdates

[[ "${TODO_UPLOAD:-0}" == "1" ]] && echo "Upload requested (destination=upload); see output above." || echo "Export in $OUT/export - upload manually, see docs/TESTFLIGHT.md"
