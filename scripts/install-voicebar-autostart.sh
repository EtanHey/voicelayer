#!/usr/bin/env bash
# Install VoiceBar's macOS login autostart LaunchAgent.
#
# Live-safe by default: a fresh install bootstraps and starts the bar now; an
# in-place update only refreshes the on-disk plist (active on next login).
# Repair callers that already stopped VoiceBar can pass --reload so launchd
# adopts the repaired definition immediately. Callers that must leave VoiceBar
# stopped can pass --no-start to install the plist without loading it.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="com.voicelayer.voicebar"
PLIST_SRC="$ROOT_DIR/launchd/$LABEL.plist"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
RELOAD=0
NO_START=0

reload_launch_agent() {
  local bootout_output=""
  local attempt
  local unloaded=0

  if ! bootout_output="$(launchctl bootout "$DOMAIN/$LABEL" 2>&1)"; then
    # The job can disappear between the loaded-state probe and bootout. Treat
    # that race as success only when a fresh probe confirms it is gone.
    if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
      printf 'ERROR: launchctl bootout failed: %s\n' \
        "${bootout_output:-unknown error}" >&2
      return 1
    fi
  fi

  # bootout is asynchronous. Do not race bootstrap against the old job.
  for ((attempt = 1; attempt <= 10; attempt++)); do
    if ! launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
      unloaded=1
      break
    fi
    sleep 0.2
  done
  if [[ "$unloaded" -eq 0 ]]; then
    echo "ERROR: $LABEL did not finish unloading" >&2
    return 1
  fi

  launchctl bootstrap "$DOMAIN" "$PLIST_DST"
  launchctl kickstart "$DOMAIN/$LABEL"
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --reload)
      RELOAD=1
      shift
      ;;
    --no-start)
      NO_START=1
      shift
      ;;
    -h|--help)
      cat <<'EOF'
Usage: install-voicebar-autostart.sh [--reload|--no-start]

  --reload  reload an already-loaded LaunchAgent after writing the canonical
            plist. Use only when the caller has already stopped VoiceBar.
  --no-start
            install the canonical plist without loading or starting VoiceBar.
EOF
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ "$RELOAD" -eq 1 && "$NO_START" -eq 1 ]]; then
  echo "ERROR: --reload and --no-start are mutually exclusive" >&2
  exit 2
fi

if [[ ! -f "$PLIST_SRC" ]]; then
  echo "ERROR: plist template not found: $PLIST_SRC" >&2
  exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"

if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  if cmp -s "$PLIST_SRC" "$PLIST_DST"; then
    if [[ "$RELOAD" -eq 0 ]]; then
      echo "Installed $LABEL (already current)"
      exit 0
    fi
  else
    cp "$PLIST_SRC" "$PLIST_DST"
    plutil -lint "$PLIST_DST" >/dev/null
  fi

  if [[ "$RELOAD" -eq 0 ]]; then
    echo "Installed $LABEL (refreshed plist; applies on next login)"
    exit 0
  fi

  reload_launch_agent
  echo "Installed $LABEL (reloaded)"
  exit 0
fi

# Fresh install: write the plist, then bootstrap and start the bar now.
cp "$PLIST_SRC" "$PLIST_DST"
plutil -lint "$PLIST_DST" >/dev/null

if [[ "$NO_START" -eq 1 ]]; then
  echo "Installed $LABEL (not started)"
  exit 0
fi

launchctl bootstrap "$DOMAIN" "$PLIST_DST"
launchctl kickstart "$DOMAIN/$LABEL"

echo "Installed $LABEL"
