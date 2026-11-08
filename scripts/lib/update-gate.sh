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
    # The TS supervisor owns restoration after commit, including disabled state.
    [[ "${VOICELAYER_INSTALL_OPERATION:-}" =~ \"source\"[[:space:]]*:[[:space:]]*\"supervised-bootstrap\" ]] && return 0
    local status
    [[ -n "${VOICELAYER_GATE_RESTORE_APP:-}" ]] || return 0
    if pgrep -U "$(id -u)" -x VoiceBar >/dev/null 2>&1; then
        if [[ "$VOICELAYER_GATE_RESTORE_APP" == /Applications/VoiceBar.app ]]; then
            source "$(dirname "${BASH_SOURCE[0]}")/voicebar-launchagent.sh"
            voicebar_verify_launchd "$VOICELAYER_GATE_RESTORE_APP" || {
                echo 'ERROR: running VoiceBar is not owned by launchd' >&2; return 1;
            }
        fi
        return 0
    else status=$?; fi
    [[ "$status" -eq 1 ]] || return 1
    if [[ "$VOICELAYER_GATE_RESTORE_APP" != /Applications/VoiceBar.app ]]; then
        open "$VOICELAYER_GATE_RESTORE_APP" || return 1 # Separate, isolated QA identity.
        vl_gate_wait_voicebar
        return
    fi
    source "$(dirname "${BASH_SOURCE[0]}")/voicebar-launchagent.sh"
    voicebar_start_launchd "$VOICELAYER_GATE_RESTORE_APP"
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

# 2.2.58 upgrades its formula before invoking these NEW repair scripts, without
# a target or lease. It cannot safely run destructive dedupe/reload, nor finish
# a newly committed lease. Use the existing non-destructive cask availability
# path instead; setup preserves gate evidence and fences a live controller.
vl_gate_legacy_formula_availability() {
    local root runtime
    [[ -z "${VOICELAYER_INSTALL_OPERATION:-}" &&
       -z "${HOMEBREW_VOICELAYER_INSTALL_OPERATION:-}" &&
       -z "${VOICELAYER_UPDATE_TARGET_SHA:-}" ]] || return 0
    root="$(cd "$1" && pwd -P)" || return 1
    [[ "$root" =~ ^/(opt/homebrew|usr/local)/Cellar/voicelayer/[^/]+/libexec/lib/node_modules/voicelayer-mcp$ ]] || return 0
    runtime="$(vl_gate_bun)" || {
        echo "[update-gate] REFUSED UNKNOWN: bun runtime not found; nothing was changed" >&2
        return 1
    }
    echo "[update-gate] Legacy formula repair: restoring canonical availability; destructive dedupe/reload deferred (no update lease)." >&2
    exec "$runtime" "$root/src/cli/setup.ts" "$root" --cask-postflight
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
        vl_gate_capture_voicebar "${BASH_SOURCE[1]}" || return 1
        exec "$runtime" "$root/src/update-gate-installer.ts" "$@"
    fi
}
