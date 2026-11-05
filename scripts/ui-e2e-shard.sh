#!/usr/bin/env bash
set -euo pipefail
exec python3 "$(dirname "$0")/ui-e2e-shard.py" "$@"
