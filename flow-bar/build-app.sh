#!/usr/bin/env bash
# Build VoiceBar as a proper macOS .app bundle.
#
# Usage: bash flow-bar/build-app.sh
#
# Output: /Applications/VoiceBar.app

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_DIR="$SCRIPT_DIR"
BUNDLE_DIR="$SCRIPT_DIR/bundle"
APP_DIR="/Applications/VoiceBar.app"
SIGN_IDENTITY="${VOICEBAR_CODESIGN_IDENTITY:-Apple Development: Etan Heyman (DXHB5E7P2D)}"

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

# Developer signing keeps TCC permissions stable across rebuilds.
echo "[build-app] Signing..."
codesign --force --deep --sign "$SIGN_IDENTITY" --timestamp=none "$APP_DIR"

echo "[build-app] Verifying signature..."
if ! codesign -dv --verbose=4 "$APP_DIR" 2>&1 | grep -F "Authority=$SIGN_IDENTITY" >/dev/null; then
    echo "[build-app] ERROR: Installed app is not signed with $SIGN_IDENTITY"
    codesign -dv --verbose=4 "$APP_DIR" 2>&1
    exit 1
fi

echo "[build-app] Done: $APP_DIR"
echo "[build-app] To add to Login Items: System Settings > General > Login Items > +"
echo "[build-app] Or run: osascript -e 'tell application \"System Events\" to make login item at end with properties {path:\"/Applications/VoiceBar.app\", hidden:true}'"
