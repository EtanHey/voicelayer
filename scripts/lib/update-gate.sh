#!/usr/bin/env bash
# One controller owns commit; nested scripts validate its persisted lease.
vl_update_gate() {
    local root="$1"; shift
    if [[ -n "${VOICELAYER_INSTALL_OPERATION:-}" ]]; then
        bun "$root/src/update-gate-installer.ts" --validate || return 1
    else
        exec bun "$root/src/update-gate-installer.ts" "$@"
    fi
}
