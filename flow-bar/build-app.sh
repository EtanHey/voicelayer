#!/usr/bin/env bash
# Build VoiceBar as a proper macOS .app bundle.
#
# Usage: bash flow-bar/build-app.sh [--install-path /Applications/VoiceBar.app]
#
# Output: /Applications/VoiceBar.app by default

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_DIR="$SCRIPT_DIR"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLE_DIR="$SCRIPT_DIR/bundle"
APP_DIR="/Applications/VoiceBar.app"
SIGN_IDENTITY="${VOICEBAR_CODESIGN_IDENTITY:-Apple Development: Etan Heyman (DXHB5E7P2D)}"
VOICEBAR_BACKUP_DIR="${VOICEBAR_BACKUP_DIR:-$HOME/Library/Application Support/VoiceBar/Backups}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install-path)
            if [[ $# -lt 2 ]]; then
                echo "[build-app] ERROR: --install-path requires a target path"
                exit 1
            fi
            APP_DIR="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: bash flow-bar/build-app.sh [--install-path /Applications/VoiceBar.app]"
            exit 0
            ;;
        *)
            echo "[build-app] ERROR: Unknown argument: $1"
            exit 1
            ;;
    esac
done

echo "[build-app] Building VoiceBar (release)..."
swift build -c release --package-path "$PACKAGE_DIR"

# Find the built binary (reuses cached build, no rebuild)
BIN_DIR="$(swift build -c release --package-path "$PACKAGE_DIR" --show-bin-path)"
BINARY="$BIN_DIR/VoiceBar"
if [ ! -f "$BINARY" ]; then
    echo "[build-app] ERROR: Binary not found at $BINARY"
    exit 1
fi

# Clean stale bundle before recreating. The production app is guarded so Etan's
# resident VoiceBar is never removed while it is actively running, and the old
# bundle is moved to a pruned backup dir (outside /Applications) rather than rm'd.
if [ -d "$APP_DIR" ]; then
    if [ "$APP_DIR" = "/Applications/VoiceBar.app" ] &&
       pgrep -x VoiceBar >/dev/null 2>&1 &&
       [ "${VOICEBAR_FORCE_APP_REPLACE:-0}" != "1" ]; then
        echo "[build-app] ERROR: Refusing to replace /Applications/VoiceBar.app while VoiceBar is running." >&2
        echo "[build-app] Quit VoiceBar first, or set VOICEBAR_FORCE_APP_REPLACE=1 only after Etan says go." >&2
        exit 1
    fi

    if [ "$APP_DIR" = "/Applications/VoiceBar.app" ]; then
        mkdir -p "$VOICEBAR_BACKUP_DIR"
        backup_path="$VOICEBAR_BACKUP_DIR/VoiceBar.backup-$(date +%Y%m%d-%H%M%S).app.zip"
        echo "[build-app] Archiving old bundle to $backup_path..."
        ditto -c -k --keepParent "$APP_DIR" "$backup_path"
        rm -rf "$APP_DIR"
        # Keep only the most recent backup; prune older ones.
        find "$VOICEBAR_BACKUP_DIR" -maxdepth 1 -name 'VoiceBar.backup-*.app.zip' -type f \
            | sort -r | sed -n '2,$p' | while IFS= read -r old_backup; do
                rm -f "$old_backup"
            done
    else
        echo "[build-app] Removing old bundle..."
        rm -rf "$APP_DIR"
    fi
fi

echo "[build-app] Creating .app bundle at $APP_DIR..."
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

require_bundle_file() {
    local rel_path="$1"
    if [ ! -f "$REPO_ROOT/$rel_path" ]; then
        echo "[build-app] ERROR: required bundle file missing: $rel_path" >&2
        exit 1
    fi
}

cp "$BUNDLE_DIR/Info.plist" "$APP_DIR/Contents/"
cp "$BINARY" "$APP_DIR/Contents/MacOS/VoiceBar"
cp -R "$REPO_ROOT/src" "$APP_DIR/Contents/Resources/"
if [ -f "$REPO_ROOT/package.json" ]; then
    cp "$REPO_ROOT/package.json" "$APP_DIR/Contents/Resources/package.json"
fi

# Bundle the Silero VAD model — recording fails at the first chunk without it
# (vad.ts findModelPath resolves models/ relative to the bundled src). Omitting
# this silently breaks recording on every rebuild.
if [ -f "$REPO_ROOT/models/silero_vad.onnx" ]; then
    cp -R "$REPO_ROOT/models" "$APP_DIR/Contents/Resources/"
    echo "[build-app] VAD model bundled."
else
    echo "[build-app] WARNING: models/silero_vad.onnx not found — recording will fail until it is present." >&2
fi

# Bundle the edge-tts synth script — ALL daemon TTS fails (edge-tts exit code 2)
# without it (tts.ts resolves ../scripts/edge-tts-words.py relative to the
# bundled src). Same silent-loss bug class as the VAD model above (#241).
if [ -f "$REPO_ROOT/scripts/edge-tts-words.py" ]; then
    mkdir -p "$APP_DIR/Contents/Resources/scripts"
    cp "$REPO_ROOT/scripts/edge-tts-words.py" "$APP_DIR/Contents/Resources/scripts/"
    echo "[build-app] edge-tts synth script bundled."
else
    echo "[build-app] WARNING: scripts/edge-tts-words.py not found — daemon TTS will fail until it is present." >&2
fi

require_bundle_file "scripts/install-voicebar-f5-hidutil.sh"
require_bundle_file "scripts/apply-voicebar-f5-hidutil.sh"
require_bundle_file "launchd/com.voicelayer.f5-to-f18-hidutil.plist"
mkdir -p "$APP_DIR/Contents/Resources/scripts"
mkdir -p "$APP_DIR/Contents/Resources/launchd"
cp "$REPO_ROOT/scripts/install-voicebar-f5-hidutil.sh" "$APP_DIR/Contents/Resources/scripts/"
cp "$REPO_ROOT/scripts/apply-voicebar-f5-hidutil.sh" "$APP_DIR/Contents/Resources/scripts/"
cp "$REPO_ROOT/launchd/com.voicelayer.f5-to-f18-hidutil.plist" "$APP_DIR/Contents/Resources/launchd/"
chmod 755 "$APP_DIR/Contents/Resources/scripts/install-voicebar-f5-hidutil.sh"
chmod 755 "$APP_DIR/Contents/Resources/scripts/apply-voicebar-f5-hidutil.sh"
echo "[build-app] F5 hidutil setup files bundled."

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
if [ "${VOICEBAR_SKIP_LAUNCHD_INSTALL:-0}" = "1" ]; then
    echo "[build-app] Skipping retired MCP daemon LaunchAgent cleanup."
elif [ "$APP_DIR" != "/Applications/VoiceBar.app" ]; then
    echo "[build-app] Skipping retired MCP daemon LaunchAgent cleanup."
else
    echo "[build-app] Retiring MCP daemon LaunchAgent..."
    bash "$REPO_ROOT/launchd/install.sh"
fi
echo "[build-app] To add to Login Items: System Settings > General > Login Items > +"
echo "[build-app] Or run: osascript -e 'tell application \"System Events\" to make login item at end with properties {path:\"$APP_DIR\", hidden:true}'"
