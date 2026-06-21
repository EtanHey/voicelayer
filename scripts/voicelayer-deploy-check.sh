#!/usr/bin/env bash
# Post-merge deploy freshness check (Track 5 #1).
#
# Verifies that code merged to main has actually been DELIVERED to (and is live
# on) this Mac — the installed VoiceBar.app was rebuilt from the current version
# and the stack (app + MCP daemon child) is running. Build-green + PR-merged is
# not "deployed"; this is the gate that proves the artifact reached the machine.
#
# Exit 0 = deployed & live (or non-applicable box); exit 1 = stale / not deployed.
#
# Usage: scripts/voicelayer-deploy-check.sh
#        bash scripts/voicelayer-deploy-check.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if ! command -v bun >/dev/null 2>&1; then
    echo "ERROR: bun is required to run the deploy check." >&2
    exit 2
fi

exec bun run "$PACKAGE_ROOT/src/deploy-check-cli.ts" "$@"
