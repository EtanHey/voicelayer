#!/bin/bash
# Invoke heavy builds through the machine's configured build gate.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
case "${1:-status}" in
  build|stamp) exec python3 "$root/scripts/lib/qa-candidate-2.3.py" "$@" ;;
  *) exec python3 "$root/scripts/lib/qa-candidate-lifecycle.py" "$@" ;;
esac
