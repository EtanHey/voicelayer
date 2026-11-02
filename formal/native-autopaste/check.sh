#!/usr/bin/env bash
set -eu
root=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$root/../../.build.noindex"
run=$(mktemp -d "$root/../../.build.noindex/native-autopaste.XXXXXX")
cd "$root"
check() {
  config=$1 expected=$2 property=$3
  log="$run/$config.log"
  set +e
  nice -n 19 java -XX:+UseParallelGC -cp "$HOME/.cache/tla/tla2tools.jar" tlc2.TLC \
    -workers 1 -seed 1 -fp 0 -metadir "$run/$config" \
    -config "$config" NativeAutoPaste.tla > "$log" 2>&1
  actual=$?
  set -e
  if [ "$actual" -ne "$expected" ]; then
    cat "$log"
    printf '%s: expected exit %s, got %s\n' "$config" "$expected" "$actual" >&2
    exit 1
  fi
  if [ "$expected" -eq 0 ]; then
    grep -Fq 'Model checking completed. No error has been found.' "$log"
  elif ! grep -Fq "Error: Invariant $property is violated." "$log"; then
    cat "$log"
    printf '%s: did not fail %s\n' "$config" "$property" >&2
    exit 1
  fi
  printf '%s\texit=%s\t%s\tPASS\n' "$config" "$actual" "$property"
}
check Fixed.cfg 0 all
check Current.cfg 12 EligibleDelivery
check Mutant.cfg 12 NoDisabledDelivery
check MutantType.cfg 12 TypeOK
check MutantWrongApp.cfg 12 NoWrongApp
check MutantDouble.cfg 12 NoDoubleDelivery
check MutantRetention.cfg 12 Retention
check MutantEligible.cfg 12 EligibleDelivery
printf 'logs: %s\n' "$run"
