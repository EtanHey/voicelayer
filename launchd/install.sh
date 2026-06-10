#!/usr/bin/env bash
# Retire the old VoiceLayer MCP daemon LaunchAgent.
#
# Usage:
#   ./launchd/install.sh          # stop and remove the retired daemon agent
#   ./launchd/install.sh --uninstall  # same as above, kept for compatibility
set -euo pipefail

LABEL="com.voicelayer.mcp-daemon"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
DAEMON_DISABLE_FLAG="/tmp/.voicelayer-daemon-disabled"

if [[ "${1:-}" != "" && "${1:-}" != "--uninstall" ]]; then
    printf 'Usage: %s [--uninstall]\n' "$0" >&2
    exit 2
fi

printf 'Retiring %s...\n' "$LABEL"
printf '  plist:        %s\n' "$PLIST_DST"
printf '  disable flag: %s (left unchanged)\n' "$DAEMON_DISABLE_FLAG"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST_DST"

printf 'Retired. VoiceBar.app now owns the MCP daemon child process.\n'
