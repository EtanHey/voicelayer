#!/usr/bin/env bash
set -euo pipefail

model_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$model_dir/../.." && pwd)
logs=${1:-"$repo_root/docs.local/lane-h/tlc-fix"}
scratch="$repo_root/.build.noindex/tlc-history-check"
mkdir -p "$logs" "$scratch"

check() {
    local config=$1 expected=$2 property=$3 rc=0
    local log="$logs/${config%.cfg}.log"
    "${TLC:-$repo_root/formal/tlc.sh}" -workers 1 -metadir "$scratch/${config%.cfg}" -config "$model_dir/$config" \
        "$model_dir/HistoryRowRefresh.tla" > "$log" 2>&1 || rc=$?
    if [[ "$expected" == PASS ]]; then
        if [[ "$rc" != 0 ]] || ! grep -Fq 'Model checking completed. No error has been found.' "$log"; then
            cat "$log"
            return 1
        fi
    elif [[ "$rc" != 12 ]] || ! grep -Fq "Error: Invariant $property is violated." "$log"; then
        printf 'MUTANT DID NOT FAIL ON %s: %s (exit %s)\n' "$property" "$config" "$rc"
        cat "$log"
        return 1
    fi
    printf '%s: %s, property=%s, exit=%s\n' "$config" "$expected" "$property" "$rc"
}

check Fixed.cfg PASS PagingNotCancelled,SettledPageIsFresh
check OldReload.cfg EXPECTED_FAIL PagingNotCancelled
check UnfencedPatch.cfg EXPECTED_FAIL SettledPageIsFresh
