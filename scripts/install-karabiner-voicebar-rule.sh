#!/usr/bin/env bash
# Deprecated: VoiceBar F5 routing now uses macOS hidutil, not Karabiner.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "VoiceBar F5 routing uses hidutil now; installing hidutil LaunchAgent instead." >&2
exec "$SCRIPT_DIR/install-voicebar-f5-hidutil.sh" "$@"
