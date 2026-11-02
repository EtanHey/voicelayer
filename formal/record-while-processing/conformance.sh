#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
exec nice -n 19 bun test formal/record-while-processing/conformance.test.ts
