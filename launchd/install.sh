#!/bin/bash
# Install VoiceLayer MCP daemon as a macOS LaunchAgent.
#
# Usage:
#   ./launchd/install.sh          # install and start
#   ./launchd/install.sh --uninstall  # stop and remove
set -euo pipefail

LABEL="com.voicelayer.mcp-daemon"
PLIST_SRC="$(cd "$(dirname "$0")" && pwd)/$LABEL.plist"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
VOICELAYER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUN_BIN="$(which bun 2>/dev/null || echo "$HOME/.bun/bin/bun")"

# --- Uninstall ---
if [[ "${1:-}" == "--uninstall" ]]; then
    echo "Stopping $LABEL..."
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST_DST"
    echo "Uninstalled."
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
echo "Installing $LABEL..."
echo "  bun:        $BUN_BIN"
echo "  voicelayer:  $VOICELAYER_DIR"
echo "  plist:       $PLIST_DST"
if [[ "${DISABLE_VOICELAYER:-}" == "1" ]]; then
    echo "  disabled:    1"
fi

# Stop existing if running
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

# Generate plist from template
mkdir -p "$HOME/Library/LaunchAgents"
sed \
    -e "s|__BUN_BIN__|$BUN_BIN|g" \
    -e "s|__VOICELAYER_DIR__|$VOICELAYER_DIR|g" \
    -e "s|__HOME__|$HOME|g" \
    "$PLIST_SRC" > "$PLIST_DST"

if [[ "${DISABLE_VOICELAYER:-}" == "1" ]]; then
    /usr/libexec/PlistBuddy -c "Delete :EnvironmentVariables:DISABLE_VOICELAYER" "$PLIST_DST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:DISABLE_VOICELAYER string 1" "$PLIST_DST"
fi

# Load and start
launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"

# Verify
sleep 2
if launchctl print "gui/$(id -u)/$LABEL" > /dev/null 2>&1; then
    echo "Started. Verify: launchctl list | grep voicelayer"
    echo "Logs:   tail -f /tmp/voicelayer-mcp-daemon.stderr.log"
    echo "Socket: /tmp/voicelayer-mcp.sock"
    echo "Disable on boot: DISABLE_VOICELAYER=1 ./launchd/install.sh"
    echo ""
    echo "MCP client config (.mcp.json):"
    echo '  "voicelayer": { "command": "socat", "args": ["STDIO", "UNIX-CONNECT:/tmp/voicelayer-mcp.sock"] }'
else
    echo "WARNING: daemon may not have started. Check: tail /tmp/voicelayer-mcp-daemon.stderr.log" >&2
fi
