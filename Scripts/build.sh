#!/bin/bash
# Builds build/DockStat.app.
#
#   Scripts/build.sh                 # this Mac's architecture, ad-hoc signed
#   Scripts/build.sh --universal     # Apple Silicon + Intel in one app
#   Scripts/build.sh --sign "Developer ID Application: Your Name (TEAMID)"
#   Scripts/build.sh --dev           # developer shortcut, see below
#
# --dev pins the code-signing identity to the bundle ID only, so macOS keeps the
# Accessibility permission across rebuilds while you work on DockStat. Never ship a --dev
# build: any app claiming the same bundle ID would inherit that permission.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="DockStat"
BUNDLE_ID="com.preston100.DockStat"
APP="build/${APP_NAME}.app"
UNIVERSAL=0
IDENTITY="-"
DEV=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --universal) UNIVERSAL=1 ;;
    --sign) IDENTITY="$2"; shift ;;
    --dev) DEV=1 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

FRAMEWORKS=(-framework AppKit -framework SwiftUI -framework IOKit -framework ApplicationServices -framework ServiceManagement)
SOURCES=(Sources/DockStat/*.swift)

rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" build/obj

if [[ ${UNIVERSAL} == 1 ]]; then
  echo "==> Compiling for Apple Silicon and Intel..."
  swiftc -O -target arm64-apple-macos14.0 "${FRAMEWORKS[@]}" "${SOURCES[@]}" -o build/obj/${APP_NAME}-arm64
  swiftc -O -target x86_64-apple-macos14.0 "${FRAMEWORKS[@]}" "${SOURCES[@]}" -o build/obj/${APP_NAME}-x86_64
  lipo -create build/obj/${APP_NAME}-arm64 build/obj/${APP_NAME}-x86_64 -output "${APP}/Contents/MacOS/${APP_NAME}"
else
  ARCH="$(uname -m)"
  echo "==> Compiling for ${ARCH}..."
  swiftc -O -target "${ARCH}-apple-macos14.0" "${FRAMEWORKS[@]}" "${SOURCES[@]}" -o "${APP}/Contents/MacOS/${APP_NAME}"
fi

cp Resources/Info.plist "${APP}/Contents/Info.plist"
cp Resources/AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"

echo "==> Signing..."
if [[ ${DEV} == 1 ]]; then
  codesign --force --sign - --identifier "${BUNDLE_ID}" \
    -r="designated => identifier \"${BUNDLE_ID}\"" "${APP}"
elif [[ "${IDENTITY}" == "-" ]]; then
  # Ad-hoc: runs on this Mac. After a rebuild macOS treats it as a new app, so
  # Accessibility may need to be switched off and on again for DockStat.
  codesign --force --sign - --identifier "${BUNDLE_ID}" "${APP}"
else
  # Developer ID with the hardened runtime, ready for notarization.
  codesign --force --sign "${IDENTITY}" --options runtime --timestamp "${APP}"
fi
echo "==> Built ${APP}"
