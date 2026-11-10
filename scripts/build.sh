#!/bin/bash
# Builds build/NowBar.app for Apple Silicon. Pass --install to replace /Applications/NowBar.app.
#
# Code signing: macOS ties the "control Spotify" permission to the app's signature, and ad hoc
# builds get a new one every time, so you'd have to allow it again after each rebuild. To avoid
# that, run scripts/make-signing-identity.sh once. The build then signs with "NowBar Local Signing".
# To use a different identity, set NOWBAR_SIGN_IDENTITY, either in the environment or in
# scripts/local.env (git-ignored).
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -f scripts/local.env ]]; then
  # shellcheck disable=SC1091
  source scripts/local.env
fi

swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
APP="build/NowBar.app"

if [[ ! -f Resources/AppIcon.icns ]]; then
  scripts/make-icon.sh
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/NowBar" "$APP/Contents/MacOS/NowBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
IDENTITY="${NOWBAR_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]] && security find-certificate -c "NowBar Local Signing" >/dev/null 2>&1; then
  IDENTITY="NowBar Local Signing"
fi
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed: ${IDENTITY:-ad hoc})"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x NowBar || true
  rm -rf /Applications/NowBar.app
  cp -R "$APP" /Applications/NowBar.app
  echo "Installed /Applications/NowBar.app"
fi
