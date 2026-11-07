#!/usr/bin/env bash
# Boundary probes: each MUST fail (TLC exit 13). They drop one liveness excuse
# to show the fail-closed design does not promise release in that case.
# Usage: TLA2TOOLS=/path/to/tla2tools.jar bash formal/update-gate-lease/boundary/check.sh
set -euo pipefail
cd "$(dirname "$0")/.."
jar="${TLA2TOOLS:?set TLA2TOOLS to a tla2tools.jar}"
for cfg in boundary/*.cfg; do
  meta=$(mktemp -d); rc=0
  java -cp "$jar" tlc2.TLC -workers 1 -seed 1 -fp 0 -metadir "$meta" -config "$cfg" LeasedUpdate.tla >"$meta/out" 2>&1 || rc=$?
  rm -rf "$meta"
  if [ "$rc" -ne 13 ]; then echo "$cfg: expected temporal violation (13), got $rc" >&2; exit 1; fi
  echo "$cfg: EXPECTED_FAIL (liveness excuse is necessary)"
done
