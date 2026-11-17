#!/bin/bash
# Makes a downloadable release: build/DockStat-<version>.zip (universal).
#
# Unsigned (anyone can run this):
#   Scripts/release.sh
#   Downloads of this zip are blocked by Gatekeeper until the user right-clicks → Open,
#   or runs: xattr -dr com.apple.quarantine /Applications/DockStat.app
#
# Signed and notarized (needs a paid Apple Developer account):
#   1. Install your "Developer ID Application" certificate in Keychain.
#   2. Once: xcrun notarytool store-credentials dockstat-notary \
#              --apple-id you@example.com --team-id TEAMID
#   3. DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
#      NOTARY_PROFILE=dockstat-notary Scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
ZIP="build/DockStat-${VERSION}.zip"

if [[ -n "${DEVELOPER_ID:-}" ]]; then
  Scripts/build.sh --universal --sign "${DEVELOPER_ID}"
else
  Scripts/build.sh --universal
fi

rm -f "${ZIP}"
ditto -c -k --keepParent build/DockStat.app "${ZIP}"

if [[ -n "${DEVELOPER_ID:-}" && -n "${NOTARY_PROFILE:-}" ]]; then
  echo "==> Notarizing (takes a few minutes)..."
  xcrun notarytool submit "${ZIP}" --keychain-profile "${NOTARY_PROFILE}" --wait
  xcrun stapler staple build/DockStat.app
  rm -f "${ZIP}"
  ditto -c -k --keepParent build/DockStat.app "${ZIP}"
fi

echo "==> Release ready: ${ZIP}"
shasum -a 256 "${ZIP}"
