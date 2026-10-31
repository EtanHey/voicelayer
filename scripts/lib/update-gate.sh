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
# Capture only an observed bundle, before controlled quit. Nested helpers do not
# own restoration: the first caller's re-exec restores after all mutations finish.
vl_gate_script_path() { (cd "$(dirname "$1")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$1")"); }
vl_gate_capture_voicebar() {
    local caller="$1"
    local pids status executable
    export VOICELAYER_GATE_RESTORE_APP="" VOICELAYER_GATE_RESTORE_LAUNCHD=0
    if pids="$(pgrep -x VoiceBar 2>/dev/null)"; then
        [[ "$pids" =~ ^[0-9]+$ ]] || { echo "[update-gate] REFUSED UNKNOWN: ambiguous VoiceBar owners" >&2; return 1; }
        executable="$(ps -p "$pids" -o comm=)" || return 1
        case "$executable" in /*.app/Contents/MacOS/VoiceBar) ;; *)
            echo "[update-gate] REFUSED UNKNOWN: VoiceBar bundle unavailable for restoration" >&2; return 1;; esac
        export VOICELAYER_GATE_RESTORE_APP="${executable%/Contents/MacOS/VoiceBar}"
        [[ -d "$VOICELAYER_GATE_RESTORE_APP" ]] || return 1
        # A loaded canonical job cannot restore a separately running QA bundle.
        if [[ "$VOICELAYER_GATE_RESTORE_APP" == /Applications/VoiceBar.app ]] &&
           launchctl list com.voicelayer.voicebar >/dev/null 2>&1; then
            export VOICELAYER_GATE_RESTORE_LAUNCHD=1
        fi
    else
        status=$?; [[ "$status" -eq 1 ]] || return 1
    fi
    VOICELAYER_GATE_RESTORE_CALLER="$(vl_gate_script_path "$caller")" || return 1
    export VOICELAYER_GATE_RESTORE_CALLER
}
vl_gate_wait_voicebar() {
    local attempt status
    for ((attempt=0; attempt<50; attempt++)); do
        if pgrep -x VoiceBar >/dev/null 2>&1; then return 0; else status=$?; fi
        [[ "$status" -eq 1 ]] || return 2
        sleep 0.1
    done
    return 1
}
vl_gate_restore_voicebar() {
    local status
    [[ -n "${VOICELAYER_GATE_RESTORE_APP:-}" ]] || return 0
    if pgrep -x VoiceBar >/dev/null 2>&1; then return 0; else status=$?; fi
    [[ "$status" -eq 1 ]] || return 1
    if [[ "${VOICELAYER_GATE_RESTORE_LAUNCHD:-0}" == 1 ]]; then
        # A failed kickstart can still have started the job. Observe before fallback.
        launchctl kickstart "gui/$(id -u)/com.voicelayer.voicebar" || true
        if vl_gate_wait_voicebar; then return 0; else status=$?; fi
        [[ "$status" -eq 1 ]] || return 1
    fi
    open "$VOICELAYER_GATE_RESTORE_APP" || return 1
    vl_gate_wait_voicebar
}
vl_gate_restore_exit() {
    local status=$?
    trap - EXIT
    trap '' HUP INT TERM QUIT
    if ! vl_gate_restore_voicebar; then
        echo "[update-gate] RECOVERY_REQUIRED: could not restore observed VoiceBar bundle: $VOICELAYER_GATE_RESTORE_APP" >&2
        [[ "$status" -ne 0 ]] || status=1
    fi
    exit "$status"
}
vl_gate_arm_restore() {
    [[ -n "${VOICELAYER_INSTALL_OPERATION:-}" && -n "${VOICELAYER_GATE_RESTORE_CALLER:-}" ]] || return 0
    [[ "$(vl_gate_script_path "$1")" == "$VOICELAYER_GATE_RESTORE_CALLER" ]] || return 0
    trap vl_gate_restore_exit EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 131' QUIT
}
vl_gate_arm_restore "${BASH_SOURCE[1]:-$0}"

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
        vl_gate_capture_voicebar "${BASH_SOURCE[1]}" || return 1
        exec "$runtime" "$root/src/update-gate-installer.ts" "$@"
    fi
}
