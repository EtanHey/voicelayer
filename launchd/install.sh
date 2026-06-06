#!/usr/bin/env bash
# Install VoiceLayer MCP daemon as a macOS LaunchAgent.
#
# Usage:
#   ./launchd/install.sh          # install and start
#   ./launchd/install.sh --uninstall  # stop and remove
set -euo pipefail

LABEL="com.voicelayer.mcp-daemon"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="${VOICEBAR_APP_DIR:-/Applications/VoiceBar.app}"
BUNDLE_RESOURCES_DIR="$APP_DIR/Contents/Resources"
PLIST_SRC="$SCRIPT_DIR/$LABEL.plist"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
BUN_BIN="${VOICELAYER_BUN_BIN:-$(command -v bun 2>/dev/null || printf '%s/.bun/bin/bun' "$HOME")}"
DAEMON_DISABLE_FLAG="/tmp/.voicelayer-daemon-disabled"
LOG_DIR="${VOICEBAR_LOG_DIR:-$HOME/Library/Logs/VoiceLayer}"

if [[ -n "${VOICEBAR_DAEMON_ROOT:-}" ]]; then
    VOICELAYER_DIR="$VOICEBAR_DAEMON_ROOT"
elif [[ -f "$BUNDLE_RESOURCES_DIR/src/mcp-server-daemon.ts" ]]; then
    VOICELAYER_DIR="$BUNDLE_RESOURCES_DIR"
else
    VOICELAYER_DIR="$REPO_ROOT"
fi

# --- Uninstall ---
if [[ "${1:-}" == "--uninstall" ]]; then
    printf 'Stopping %s...\n' "$LABEL"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST_DST"
    rm -f "$DAEMON_DISABLE_FLAG"
    printf 'Uninstalled.\n'
    exit 0
fi

# --- Pre-flight checks ---
if [[ ! -f "$PLIST_SRC" ]]; then
    echo "ERROR: plist template not found: $PLIST_SRC" >&2
    exit 1
fi

if [[ ! -x "$BUN_BIN" ]]; then
    echo "ERROR: bun not found. Install: curl -fsSL https://bun.sh/install | bash" >&2
    exit 1
fi

if [[ ! -f "$VOICELAYER_DIR/src/mcp-server-daemon.ts" ]]; then
    echo "ERROR: mcp-server-daemon.ts not found in $VOICELAYER_DIR/src/" >&2
    exit 1
fi

# --- Install ---
printf 'Installing %s...\n' "$LABEL"
printf '  bun:        %s\n' "$BUN_BIN"
printf '  voicelayer: %s\n' "$VOICELAYER_DIR"
printf '  plist:      %s\n' "$PLIST_DST"
printf '  logs:       %s\n' "$LOG_DIR"
if [[ "${DISABLE_VOICELAYER:-}" == "1" ]]; then
    printf '  DISABLE_VOICELAYER=1 (daemon exits cleanly and launchd stays idle)\n'
fi

# Stop existing if running
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

# Generate plist from template
mkdir -p "$HOME/Library/LaunchAgents"
mkdir -p "$LOG_DIR"
sed \
    -e "s|__BUN_BIN__|$BUN_BIN|g" \
    -e "s|__VOICELAYER_DIR__|$VOICELAYER_DIR|g" \
    -e "s|__HOME__|$HOME|g" \
    -e "s|__LOG_DIR__|$LOG_DIR|g" \
    "$PLIST_SRC" > "$PLIST_DST"

plutil -lint "$PLIST_DST" >/dev/null

if [[ "${DISABLE_VOICELAYER:-}" == "1" ]]; then
    /usr/libexec/PlistBuddy -c "Delete :EnvironmentVariables:DISABLE_VOICELAYER" "$PLIST_DST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:DISABLE_VOICELAYER string 1" "$PLIST_DST"
    printf "disabled\n" > "$DAEMON_DISABLE_FLAG"
else
    rm -f "$DAEMON_DISABLE_FLAG"
fi

# Load and start
launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"

# Verify
sleep 2
if launchctl print "gui/$(id -u)/$LABEL" > /dev/null 2>&1; then
    printf 'Started. Verify: launchctl list | grep voicelayer\n'
    printf 'Logs:   tail -f "%s/mcp-daemon.stderr.log"\n' "$LOG_DIR"
    printf 'Socket: /tmp/voicelayer-mcp.sock\n'
    printf 'Disable on boot: DISABLE_VOICELAYER=1 ./launchd/install.sh\n'
    printf '\n'
    printf 'MCP client config (.mcp.json):\n'
    printf '  "voicelayer": { "command": "socat", "args": ["STDIO", "UNIX-CONNECT:/tmp/voicelayer-mcp.sock"] }\n'
else
    printf 'WARNING: daemon may not have started. Check: tail "%s/mcp-daemon.stderr.log"\n' "$LOG_DIR" >&2
fi
