#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
nice -n 19 bun test formal/record-while-processing/conformance.test.ts
cd flow-bar
~/.local/state/captain-2.2.61/heavy.sh I swift test --scratch-path .build.noindex/swift --filter 'LaneGFormalConformanceTests|LaneIFormalConformanceTests'
