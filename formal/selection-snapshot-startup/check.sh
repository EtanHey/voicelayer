#!/usr/bin/env bash
set -eu
root=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$root/../../.build.noindex"
run=$(mktemp -d "$root/../../.build.noindex/selection-snapshot-startup.XXXXXX")
cd "$root"
check() {
  config=$1 expected=$2 property=$3
  set +e
  "${TLC:-$root/../tlc.sh}" \
    -workers 1 -seed 1 -fp 0 -metadir "$run/$config" -config "$config" \
    SelectionSnapshotStartup.tla > "$run/$config.log" 2>&1
  actual=$?
  set -e
  if [ "$actual" -ne "$expected" ]; then cat "$run/$config.log"; exit 1; fi
  if [ "$expected" -eq 0 ]; then
    grep -Fq 'Model checking completed. No error has been found.' "$run/$config.log"
  else
    grep -Fq "Error: Invariant $property is violated." "$run/$config.log"
  fi
  printf '%s\texit=%s\t%s\tPASS\n' "$config" "$actual" "$property"
}
check Fixed.cfg 0 all
check Current.cfg 12 ColdDelivery
check MutantStartup.cfg 12 StartupBound
check MutantRead.cfg 12 ReadBound
check MutantInvalid.cfg 12 ValidDelivery
check MutantType.cfg 12 TypeOK
printf 'logs: %s\n' "$run"
