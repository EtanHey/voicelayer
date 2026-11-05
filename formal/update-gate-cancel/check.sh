#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
python3 "$root/formal/check-model.py" "$root/formal/update-gate-cancel" "$@"
