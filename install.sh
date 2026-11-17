#!/bin/bash
# Build DockStat, install it to ~/Applications, and launch it.
#
#   ./install.sh          # normal install
#   ./install.sh --dev    # while developing: keeps Accessibility permission across rebuilds
#                         # (see Scripts/build.sh; never share a --dev build)
#
# Needs only the Xcode Command Line Tools (xcode-select --install), not full Xcode.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="DockStat"
INSTALL_DIR="$HOME/Applications"

Scripts/build.sh "$@"

echo "==> Installing to ${INSTALL_DIR}..."
pkill -x "${APP_NAME}" 2>/dev/null || true
mkdir -p "${INSTALL_DIR}"
rm -rf "${INSTALL_DIR}/${APP_NAME}.app"
cp -R "build/${APP_NAME}.app" "${INSTALL_DIR}/"

echo "==> Launching..."
open "${INSTALL_DIR}/${APP_NAME}.app"
echo "Done. DockStat now sits beside your Dock. Right-click it for options."
