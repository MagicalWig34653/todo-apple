#!/usr/bin/env bash
# Builds a TestFlight-ready iOS archive and exports an .ipa. Uploads only with TODO_UPLOAD=1.
# Env:
#   TODO_TEAM_ID        Apple Developer Team ID (required unless TODO_UNSIGNED=1)
#   TODO_BUNDLE_PREFIX  optional, overrides bundle id prefix (default from App/Config/Base.xcconfig)
#   TODO_BUILD_NUMBER   optional, reuses a number the counter handed out already (e.g. the same one for the other
#                       platform). Unset: TODO_UPLOAD=1 or TODO_ARCHIVE_ONLY=1 reserves and commits the next number
#                       (scripts/build-number.sh), otherwise the current one is used
#   TODO_VERSION        optional, overrides MARKETING_VERSION
#   TODO_OUT_DIR        output dir (default: ./build/testflight)
#   TODO_UPLOAD=1       export with destination=upload (direct upload to App Store Connect via Xcode account)
#   TODO_ARCHIVE_ONLY=1 stop after the signed archive (for an upload through a separate export step)
#   TODO_UNSIGNED=1     archive only with CODE_SIGNING_ALLOWED=NO (no export; for verification)
set -euo pipefail
# Xcode's export (-exportArchive) copies the app with rsync from PATH. Homebrew rsync 3.5.2 (/opt/homebrew/bin) makes it fail
# with "Packaging: Copy failed" (seen 13.11. FiSi export and 17.11. here), so system tools go first.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH
cd "$(dirname "$0")/.."
xcodebuild="${TODO_XCODEBUILD:-xcodebuild}"

OUT="${TODO_OUT_DIR:-$PWD/build/testflight}"
ARCHIVE="$OUT/Todo-iOS.xcarchive"
mkdir -p "$OUT"

"${TODO_XCODEGEN:-xcodegen}" generate

args=(-project Todo.xcodeproj -scheme Todo-iOS -configuration Release
      -destination 'generic/platform=iOS' -archivePath "$ARCHIVE"
      -derivedDataPath "$OUT/DerivedData")
[[ -n "${TODO_BUNDLE_PREFIX:-}" ]] && args+=("TODO_BUNDLE_ID_PREFIX=$TODO_BUNDLE_PREFIX")
[[ -n "${TODO_VERSION:-}" ]] && args+=("MARKETING_VERSION=$TODO_VERSION")
# Use the Icon Composer icon if the icon agent has added one.
if compgen -G "App/Icon/AppIcon.icon" >/dev/null; then
  args+=("ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon")
else
  echo "note: App/Icon/AppIcon.icon missing - archive has no app icon (App Store Connect will reject it)." >&2
fi

[[ "${TODO_UNSIGNED:-0}" == "1" ]] || : "${TODO_TEAM_ID:?Set TODO_TEAM_ID to your Apple Developer Team ID}"
# Last precondition: from here on a reserved number counts as used.
build="$(scripts/build-number.sh pick)"
args+=("CURRENT_PROJECT_VERSION=$build")
echo "build number: $build"

if [[ "${TODO_UNSIGNED:-0}" == "1" ]]; then
  "$xcodebuild" archive "${args[@]}" CODE_SIGNING_ALLOWED=NO
  echo "Unsigned archive: $ARCHIVE (not exportable)"
  exit 0
fi

"$xcodebuild" archive "${args[@]}" DEVELOPMENT_TEAM="$TODO_TEAM_ID" -allowProvisioningUpdates
if [[ "${TODO_ARCHIVE_ONLY:-0}" == "1" ]]; then echo "Signed archive: $ARCHIVE (build $build)"; exit 0; fi

EXPORT_PLIST="$OUT/ExportOptions.plist"
sed "s/TEAM_ID_PLACEHOLDER/$TODO_TEAM_ID/" ExportOptions.plist > "$EXPORT_PLIST"
if [[ "${TODO_UPLOAD:-0}" == "1" ]]; then
  /usr/libexec/PlistBuddy -c "Set :destination upload" "$EXPORT_PLIST"
fi
"$xcodebuild" -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$EXPORT_PLIST" \
  -exportPath "$OUT/export" -allowProvisioningUpdates

[[ "${TODO_UPLOAD:-0}" == "1" ]] && echo "Upload requested (destination=upload); see output above." || echo "IPA in $OUT/export - upload manually, see docs/TESTFLIGHT.md"
