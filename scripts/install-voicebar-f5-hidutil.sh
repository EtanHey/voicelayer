#!/usr/bin/env bash
# Install VoiceBar's macOS Dictation-key -> F18 hidutil relay.
set -euo pipefail
# A QA home must never take over the global gui/$UID relay label.
if [[ "${VOICELAYER_QA_HEALTH:-}" == 1 || "${VOICEBAR_QA_PRESERVE_OVERRIDES:-}" == 1 ||
      "${QA_VOICEBAR_PRESERVE_TEST_OVERRIDES:-}" == 1 || -n "${VOICEBAR_USER_DEFAULTS_SUITE:-}" ]]; then
  echo 'REFUSED: QA app cannot install the system F5 relay' >&2; exit 1
fi
if [[ "${VOICELAYER_TEST_ISOLATED:-}" != 1 ]]; then
  real_home="$(/usr/bin/dscl . -read "/Users/$(/usr/bin/id -un)" NFSHomeDirectory)" || exit 1
  real_home="${real_home#NFSHomeDirectory: }"
  [[ "$HOME" == "$real_home" && "${CFFIXED_USER_HOME:-$HOME}" == "$real_home" ]] || {
    echo 'REFUSED: relay installer requires the real HOME' >&2; exit 1;
  }
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Refuse before sourcing a restore trap, writing HOME or invoking a host tool.
if [[ "${VOICELAYER_TEST_ISOLATED:-}" == 1 ]]; then
  isolated_root="$(cd "${VOICELAYER_TEST_RUN_ROOT:?isolated root required}" && pwd -P)" || exit 1
  isolated_home="$(cd "${HOME:?HOME required}" && pwd -P)" || exit 1
  isolated_launchctl="$(command -v launchctl)" || exit 1
  [[ "$HOME" == "$isolated_root/"* && "$isolated_home" == "$isolated_root/"* &&
     "$isolated_launchctl" == "$isolated_root/"* && ! -L "$isolated_launchctl" ]] || {
    echo "UNKNOWN: installer HOME or launchctl escaped isolated root" >&2; exit 1;
  }
  isolated_tool_dir="$(cd "$(dirname "$isolated_launchctl")" && pwd -P)" || exit 1
  [[ "$isolated_tool_dir" == "$isolated_root/"* ]] || exit 1
fi
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

if [[ "${VOICELAYER_SETUP_AVAILABILITY:-}" == 1 ]]; then
  # Cask setup restores the relay without unloading or force-kicking a live job.
  if [[ "${VOICELAYER_SETUP_PLISTS_ONLY:-}" == 1 ]]; then exit 0; fi
  if ! launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"
  fi
  exit 0
fi
launchctl bootout "gui/$(id -u)" "$PLIST_DST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"
launchctl kickstart -k "gui/$(id -u)/$LABEL"

echo "Installed $LABEL"
hidutil property --get UserKeyMapping
