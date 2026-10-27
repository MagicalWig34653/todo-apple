#!/usr/bin/env bash
# Builds a TestFlight-ready iOS archive and exports an .ipa. Uploads NOTHING.
# Env:
#   TODO_TEAM_ID        Apple Developer Team ID (required unless TODO_UNSIGNED=1)
#   TODO_BUNDLE_PREFIX  optional, overrides bundle id prefix (default from App/Config/Base.xcconfig)
#   TODO_BUILD_NUMBER   optional, overrides CURRENT_PROJECT_VERSION
#   TODO_VERSION        optional, overrides MARKETING_VERSION
#   TODO_OUT_DIR        output dir (default: ./build/testflight)
#   TODO_UNSIGNED=1     archive only with CODE_SIGNING_ALLOWED=NO (no export; for verification)
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${TODO_OUT_DIR:-$PWD/build/testflight}"
ARCHIVE="$OUT/Todo-iOS.xcarchive"
mkdir -p "$OUT"

xcodegen generate

args=(-project Todo.xcodeproj -scheme Todo-iOS -configuration Release
      -destination 'generic/platform=iOS' -archivePath "$ARCHIVE"
      -derivedDataPath "$OUT/DerivedData")
[[ -n "${TODO_BUNDLE_PREFIX:-}" ]] && args+=("TODO_BUNDLE_ID_PREFIX=$TODO_BUNDLE_PREFIX")
[[ -n "${TODO_BUILD_NUMBER:-}" ]] && args+=("CURRENT_PROJECT_VERSION=$TODO_BUILD_NUMBER")
[[ -n "${TODO_VERSION:-}" ]] && args+=("MARKETING_VERSION=$TODO_VERSION")
# Use the Icon Composer icon if the icon agent has added one.
if compgen -G "App/Icon/AppIcon.icon" >/dev/null; then
  args+=("ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon")
else
  echo "note: App/Icon/AppIcon.icon missing - archive has no app icon (App Store Connect will reject it)." >&2
fi

if [[ "${TODO_UNSIGNED:-0}" == "1" ]]; then
  xcodebuild archive "${args[@]}" CODE_SIGNING_ALLOWED=NO
  echo "Unsigned archive: $ARCHIVE (not exportable)"
  exit 0
fi

: "${TODO_TEAM_ID:?Set TODO_TEAM_ID to your Apple Developer Team ID}"
xcodebuild archive "${args[@]}" DEVELOPMENT_TEAM="$TODO_TEAM_ID" -allowProvisioningUpdates

EXPORT_PLIST="$OUT/ExportOptions.plist"
sed "s/TEAM_ID_PLACEHOLDER/$TODO_TEAM_ID/" ExportOptions.plist > "$EXPORT_PLIST"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$EXPORT_PLIST" \
  -exportPath "$OUT/export" -allowProvisioningUpdates

echo "IPA in $OUT/export - upload manually, see docs/TESTFLIGHT.md"
