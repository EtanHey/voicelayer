#!/usr/bin/env bash
# Install VoiceBar's macOS login autostart LaunchAgent.
#
# Live-safe by default: a fresh install bootstraps and starts the bar now; an
# in-place update only refreshes the on-disk plist (active on next login).
# Repair callers that already stopped VoiceBar can pass --reload so launchd
# adopts the repaired definition immediately. Callers that must leave VoiceBar
# stopped can pass --no-start to install the plist and unload any existing job.
# Callers that must not change the current load state can pass
# --preserve-load-state.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="com.voicelayer.voicebar"
PLIST_SRC="$ROOT_DIR/launchd/$LABEL.plist"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
VOICEBAR_APP="${VOICEBAR_APP_PATH:-/Applications/VoiceBar.app}"
RELOAD=0
NO_START=0
PRESERVE_LOAD_STATE=0

unload_launch_agent() {
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
}

# Homebrew stamps com.apple.quarantine on the downloaded cask unconditionally
# (cask/download.rb) and only `brew upgrade --cask` ever offers to release it, so
# `brew install/reinstall --cask voicebar` leaves the bundle Gatekeeper-parked.
# launchd then starts an app macOS refuses to run without a user "Open?" click,
# which reads exactly like "the daemon never starts".
#
# This runs once, early, for every mode that can leave a resident bundle behind --
# not just the modes that bootstrap. The cask's postflight is `voicelayer setup`
# -> `voicelayer autostart install` with NO --reload, so on an upgrade the agent is
# already loaded and this script takes the early-exit branch without ever calling
# launchctl bootstrap. That is exactly the shape of the outage, so stripping only
# next to a bootstrap would miss the one path that actually matters.
release_quarantine() {
  if ! command -v xattr >/dev/null 2>&1; then
    return 0
  fi
  if [[ ! -d "$VOICEBAR_APP" ]]; then
    return 0
  fi
  if xattr -d -r com.apple.quarantine "$VOICEBAR_APP" 2>/dev/null; then
    return 0
  fi

  # `xattr -d` fails both when the attribute was never there (harmless, silent)
  # and when the walk could not remove it -- permissions, a read-only bundle, a
  # partially completed recursion. Only the second case matters, so re-probe
  # before making noise. Never fail the install over it: a loudly warned-about
  # bundle still beats leaving the machine with no LaunchAgent at all.
  if xattr -p com.apple.quarantine "$VOICEBAR_APP" >/dev/null 2>&1; then
    echo "WARNING: could not strip com.apple.quarantine from $VOICEBAR_APP" >&2
    echo "WARNING: macOS may refuse to launch VoiceBar until it is released" >&2
  fi
  return 0
}

reload_launch_agent() {
  unload_launch_agent
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
    --preserve-load-state)
      PRESERVE_LOAD_STATE=1
      shift
      ;;
    -h|--help)
      cat <<'EOF'
Usage: install-voicebar-autostart.sh [--reload|--no-start|--preserve-load-state]

  --reload  reload an already-loaded LaunchAgent after writing the canonical
            plist. Use only when the caller has already stopped VoiceBar.
  --no-start
            install the canonical plist and leave the LaunchAgent unloaded.
  --preserve-load-state
            refresh the plist without loading or unloading the LaunchAgent.
EOF
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if ((RELOAD + NO_START + PRESERVE_LOAD_STATE > 1)); then
  echo "ERROR: --reload, --no-start, and --preserve-load-state are mutually exclusive" >&2
  exit 2
fi

if [[ ! -f "$PLIST_SRC" ]]; then
  echo "ERROR: plist template not found: $PLIST_SRC" >&2
  exit 1
fi

release_quarantine

mkdir -p "$HOME/Library/LaunchAgents"

if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  plist_changed=0
  if ! cmp -s "$PLIST_SRC" "$PLIST_DST"; then
    cp "$PLIST_SRC" "$PLIST_DST"
    plutil -lint "$PLIST_DST" >/dev/null
    plist_changed=1
  fi

  if [[ "$NO_START" -eq 1 ]]; then
    unload_launch_agent
    echo "Installed $LABEL (not started)"
    exit 0
  fi

  if [[ "$RELOAD" -eq 0 ]]; then
    if [[ "$plist_changed" -eq 1 ]]; then
      echo "Installed $LABEL (refreshed plist; applies on next login)"
    else
      echo "Installed $LABEL (already current)"
    fi
    exit 0
  fi

  reload_launch_agent
  echo "Installed $LABEL (reloaded)"
  exit 0
fi

# Fresh install: write the plist, then bootstrap and start the bar now.
cp "$PLIST_SRC" "$PLIST_DST"
plutil -lint "$PLIST_DST" >/dev/null

if [[ "$NO_START" -eq 1 || "$PRESERVE_LOAD_STATE" -eq 1 ]]; then
  echo "Installed $LABEL (not started)"
  exit 0
fi

launchctl bootstrap "$DOMAIN" "$PLIST_DST"
launchctl kickstart "$DOMAIN/$LABEL"

echo "Installed $LABEL"
