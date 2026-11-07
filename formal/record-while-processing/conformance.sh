#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# Reuse an ancestor's serialized slot; reacquiring it here would deadlock an
# explicit `heavy.sh G bash conformance.sh` invocation. CI has its own runner.
if [[ "${CI:-}" != "true" ]] && ! python3 - <<'PY'
import os
from pathlib import Path
import subprocess
owner = Path.home() / '.local/state/captain-2.2.61/heavy.lock/owner'
try:
    expected = int(owner.read_text().split()[-1])
except (OSError, ValueError, IndexError):
    raise SystemExit(1)
pid = os.getppid()
while pid > 1:
    if pid == expected:
        raise SystemExit(0)
    value = subprocess.run(['ps', '-p', str(pid), '-o', 'ppid='], capture_output=True, text=True).stdout.strip()
    if not value:
        break
    pid = int(value)
raise SystemExit(1)
PY
then
  exec "$HOME/.local/state/captain-2.2.61/heavy.sh" G bash "$PWD/formal/record-while-processing/conformance.sh" "$@"
fi
nice -n 19 bun test formal/record-while-processing/conformance.test.ts
nice -n 19 swift test --package-path flow-bar --scratch-path .build.noindex/swift \
  --filter 'LaneGFormalConformanceTests.testBothPipelineGraphPathsAgainstNativeRouterAndDelivery|LaneIFormalConformanceTests'
