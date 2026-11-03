#!/usr/bin/env bash
# Registered configs via the shared exact-property runner (present on
# integration/2.2.61 and lane G5; absent on main 1cb914a).
set -euo pipefail
cd "$(dirname "$0")/../.."
exec python3 -B formal/check-model.py formal/update-gate-lease
