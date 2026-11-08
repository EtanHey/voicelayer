#!/usr/bin/env bash
# Safe on an occupied host. Native acceptance remains an M1 lead operation.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 scripts/e2e-2.4.py "$@"
