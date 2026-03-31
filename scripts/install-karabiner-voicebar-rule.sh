#!/usr/bin/env bash
# Install VoiceBar Karabiner rule into ~/.config/karabiner/karabiner.json
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$SCRIPT_DIR/install-karabiner-voicebar-rule.py" "$@"
