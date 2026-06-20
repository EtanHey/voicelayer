#!/usr/bin/env bash
# Install VoiceBar's macOS login autostart LaunchAgent.
#
# Live-safe by design: a fresh install bootstraps and starts the bar now; an
# in-place update only refreshes the on-disk plist (active on next login) and
# never boots out a loaded agent — Etan may be using the bar.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="com.voicelayer.voicebar"
PLIST_SRC="$ROOT_DIR/launchd/$LABEL.plist"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

if [[ ! -f "$PLIST_SRC" ]]; then
  echo "ERROR: plist template not found: $PLIST_SRC" >&2
  exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"

# Already loaded → never bootout a running bar. Only refresh the on-disk plist;
# the updated definition takes effect on the next login.
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  if cmp -s "$PLIST_SRC" "$PLIST_DST"; then
    echo "Installed $LABEL (already current)"
    exit 0
  fi
  cp "$PLIST_SRC" "$PLIST_DST"
  plutil -lint "$PLIST_DST" >/dev/null
  echo "Installed $LABEL (refreshed plist; applies on next login)"
  exit 0
fi

# Fresh install: write the plist, then bootstrap and start the bar now.
cp "$PLIST_SRC" "$PLIST_DST"
plutil -lint "$PLIST_DST" >/dev/null

launchctl bootstrap "$DOMAIN" "$PLIST_DST"
launchctl kickstart "$DOMAIN/$LABEL"

echo "Installed $LABEL"
