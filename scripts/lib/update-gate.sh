#!/usr/bin/env bash
# One controller owns commit; nested scripts validate its persisted lease.
vl_gate_bun() {
    local candidate
    local candidates=(/opt/homebrew/bin/bun "$HOME/.bun/bin/bun")
    # Harness-only resolution seam: a live preload marker, not the flag alone.
    if [[ "${VOICELAYER_TEST_ISOLATED:-}" == 1 && -n "${VOICELAYER_TEST_INSTALL_TOKEN:-}" &&
          -f "${VOICELAYER_TEST_RUN_ROOT:-}/.installer-harness.json" ]]; then
        candidates=("${VOICELAYER_TEST_BUN_CANDIDATES:-}")
    fi
    for candidate in "${candidates[@]}"; do
        if [[ -x "$candidate" && ! -d "$candidate" ]]; then printf '%s\n' "$candidate"; return 0; fi
    done
    command -v bun 2>/dev/null
}
vl_update_gate() {
    local root="$1" runtime; shift
    if [[ -z "${VOICELAYER_INSTALL_OPERATION:-}" && "$#" -eq 0 ]]; then
        echo "[update-gate] REFUSED UNKNOWN: inherited operation required; caller retained" >&2
        return 1
    fi
    runtime="$(vl_gate_bun)" || {
        echo "[update-gate] REFUSED UNKNOWN: bun runtime not found; nothing was changed" >&2
        return 1
    }
    if [[ -n "${VOICELAYER_INSTALL_OPERATION:-}" ]]; then
        "$runtime" "$root/src/update-gate-installer.ts" --validate || return 1
    else
        exec "$runtime" "$root/src/update-gate-installer.ts" "$@"
    fi
}
