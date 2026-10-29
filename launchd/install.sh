#!/usr/bin/env bash
# Retire the old VoiceLayer MCP daemon LaunchAgent.
#
# Usage:
#   ./launchd/install.sh          # stop and remove the retired daemon agent
#   ./launchd/install.sh --uninstall  # same as above, kept for compatibility
#   ./launchd/install.sh --recordings-backup  # render backup plist, do not load
set -euo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    printf 'Usage: %s [--uninstall|--recordings-backup]\n' "$0"; exit 0
fi
# Explicit opt-in; the default retirement path never installs a backup job.
if [[ "${1:-}" == "--recordings-backup" && "$#" -eq 1 ]]; then
    exec bash "$(dirname "$0")/../scripts/backup-recordings-icloud.sh" --install
fi

LABEL="com.voicelayer.mcp-daemon"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
DAEMON_DISABLE_FLAG="/tmp/.voicelayer-daemon-disabled"

if [[ "$#" -gt 1 || ( "${1:-}" != "" && "${1:-}" != "--uninstall" ) ]]; then
    printf 'Usage: %s [--uninstall|--recordings-backup]\n' "$0" >&2
    exit 2
fi

printf 'Retiring %s...\n' "$LABEL"
printf '  plist:        %s\n' "$PLIST_DST"
printf '  disable flag: %s (left unchanged)\n' "$DAEMON_DISABLE_FLAG"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/update-gate.sh"
vl_update_gate "$ROOT_DIR" bash "$ROOT_DIR/launchd/install.sh" "$@"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST_DST"

printf 'Retired. VoiceBar.app now owns the MCP daemon child process.\n'
