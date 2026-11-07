#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
if [[ "${CI:-}" == "true" ]]; then
  exec nice -n 19 swift test --package-path flow-bar --scratch-path .build.noindex/swift --filter LaneGFormalConformanceTests
fi
exec "$HOME/.local/state/captain-2.2.61/heavy.sh" G swift test --package-path flow-bar \
  --scratch-path .build.noindex/swift --filter LaneGFormalConformanceTests
