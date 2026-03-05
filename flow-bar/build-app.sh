#!/usr/bin/env bash
# Build VoiceBar as a proper macOS .app bundle.
#
# Usage: bash flow-bar/build-app.sh
#
# Output: ~/Applications/VoiceLayer/VoiceBar.app

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_DIR="$SCRIPT_DIR"
BUNDLE_DIR="$SCRIPT_DIR/bundle"
APP_DIR="/Applications/VoiceBar.app"

echo "[build-app] Building VoiceBar (release)..."
swift build -c release --package-path "$PACKAGE_DIR"

# Find the built binary (reuses cached build, no rebuild)
BIN_DIR="$(swift build -c release --package-path "$PACKAGE_DIR" --show-bin-path)"
BINARY="$BIN_DIR/VoiceBar"
if [ ! -f "$BINARY" ]; then
    echo "[build-app] ERROR: Binary not found at $BINARY"
    exit 1
fi

# Clean stale bundle before recreating
if [ -d "$APP_DIR" ]; then
    echo "[build-app] Removing old bundle..."
    rm -rf "$APP_DIR"
fi

echo "[build-app] Creating .app bundle at $APP_DIR..."
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BUNDLE_DIR/Info.plist" "$APP_DIR/Contents/"
cp "$BINARY" "$APP_DIR/Contents/MacOS/VoiceBar"

# App icon
if [ -f "$BUNDLE_DIR/VoiceBar.icns" ]; then
    cp "$BUNDLE_DIR/VoiceBar.icns" "$APP_DIR/Contents/Resources/"
    echo "[build-app] Icon installed."
fi

# Ad-hoc codesign (required for macOS Gatekeeper)
echo "[build-app] Signing..."
codesign --force --sign - "$APP_DIR"

echo "[build-app] Done: $APP_DIR"
echo "[build-app] To add to Login Items: System Settings > General > Login Items > +"
echo "[build-app] Or run: osascript -e 'tell application \"System Events\" to make login item at end with properties {path:\"/Applications/VoiceBar.app\", hidden:true}'"
