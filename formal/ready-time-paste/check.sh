#!/usr/bin/env bash
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
run=$(mktemp -d "$root/.build.noindex/ready-time-paste.XXXXXX")
cd "$root/formal/ready-time-paste"
check() {
  config=$1 expected=$2 property=$3
  set +e
  bash "$root/formal/tlc.sh" -workers 1 -seed 1 -fp 0 -metadir "$run/$config" \
    -config "$config.cfg" ReadyTimePaste.tla > "$run/$config.log" 2>&1
  actual=$?
  set -e
  if [ "$actual" -ne "$expected" ]; then cat "$run/$config.log"; exit 1; fi
  if [ "$expected" -eq 0 ]; then
    grep -Fq 'Model checking completed. No error has been found.' "$run/$config.log"
  else
    grep -Fq "Error: Invariant $property is violated." "$run/$config.log"
  fi
  printf '%s | %s | %s\n' "$config" "$actual" "$property"
  grep -E 'states generated|depth of the complete' "$run/$config.log"
}
check Fixed 0 all
check Old 12 DeliversToReadyTimeFocus
check DoubleMutant 12 DeliveredAtMostOnce
check SecureMutant 12 NeverIntoSecureField
printf 'logs: %s\n' "$run"
