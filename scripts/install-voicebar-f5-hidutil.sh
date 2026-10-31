#!/usr/bin/env bash
# Install VoiceBar's macOS Dictation-key -> F18 hidutil relay.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "${1:-}" in
  -h|--help) echo "Usage: install-voicebar-f5-hidutil.sh"; exit 0 ;;
esac
if [[ "$#" -ne 0 ]]; then echo "ERROR: this installer accepts no arguments" >&2; exit 2; fi
# Standalone Settings relay setup changes only its hidutil LaunchAgent and mapping.
# It never quits/replaces/restarts VoiceBar or its daemon, so needs no update lease or Bun.
LABEL="com.voicelayer.f5-to-f18-hidutil"
PLIST_SRC="$ROOT_DIR/launchd/$LABEL.plist"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
SUPPORT_DIR="$HOME/Library/Application Support/VoiceLayer"
HELPER_SRC="$ROOT_DIR/scripts/apply-voicebar-f5-hidutil.sh"
HELPER_DST="$SUPPORT_DIR/apply-voicebar-f5-hidutil.sh"

if [[ ! -f "$PLIST_SRC" ]]; then
  echo "ERROR: plist template not found: $PLIST_SRC" >&2
  exit 1
fi

if [[ ! -f "$HELPER_SRC" ]]; then
  echo "ERROR: hidutil helper not found: $HELPER_SRC" >&2
  exit 1
fi

mkdir -p "$SUPPORT_DIR"
cp "$HELPER_SRC" "$HELPER_DST"
chmod 755 "$HELPER_DST"

mkdir -p "$HOME/Library/LaunchAgents"
cp "$PLIST_SRC" "$PLIST_DST"
plutil -lint "$PLIST_DST" >/dev/null

launchctl bootout "gui/$(id -u)" "$PLIST_DST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"
launchctl kickstart -k "gui/$(id -u)/$LABEL"

echo "Installed $LABEL"
hidutil property --get UserKeyMapping
