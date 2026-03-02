#!/usr/bin/env bash
# Build FlowBar as a proper macOS .app bundle.
#
# Usage: bash flow-bar/build-app.sh
#
# Output: ~/Applications/VoiceLayer/FlowBar.app

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_DIR="$SCRIPT_DIR"
BUNDLE_DIR="$SCRIPT_DIR/bundle"
APP_DIR="$HOME/Applications/VoiceLayer/FlowBar.app"

echo "[build-app] Building FlowBar (release)..."
swift build -c release --package-path "$PACKAGE_DIR"

# Find the built binary
BINARY="$(swift build -c release --package-path "$PACKAGE_DIR" --show-bin-path)/FlowBar"
if [ ! -f "$BINARY" ]; then
    echo "[build-app] ERROR: Binary not found at $BINARY"
    exit 1
fi

echo "[build-app] Creating .app bundle at $APP_DIR..."
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BUNDLE_DIR/Info.plist" "$APP_DIR/Contents/"
cp "$BINARY" "$APP_DIR/Contents/MacOS/FlowBar"

# Ad-hoc codesign (required for macOS Gatekeeper)
echo "[build-app] Signing..."
codesign --force --sign - "$APP_DIR"

echo "[build-app] Done: $APP_DIR"
echo "[build-app] Add to Login Items: System Settings > General > Login Items > +"
