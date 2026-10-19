#!/usr/bin/env bash
# Mute the host output for one run and always put back the state that was found.
#
# AIDEV-NOTE (MUTE1, 2026-10-19): Etan found his Mac muted and had not muted it.
# The UIE2E runner used to mute and deliberately leave output muted, relying on
# every operator to restore it by hand. Never mute without this guard.
#
# Sourceable and side-effect free: sourcing defines functions only. Call
# output_mute_guard_begin once; it records the prior state, installs EXIT, INT and
# TERM traps that restore it, and only then mutes. The restore runs on success,
# failure and interrupt. SIGKILL cannot be trapped. A caller that needs its own
# EXIT trap must call output_mute_guard_restore from it (restore is idempotent).

output_mute_guard_prior=

output_mute_guard_restore() {
  [[ -n $output_mute_guard_prior ]] || return 0
  local prior=$output_mute_guard_prior
  output_mute_guard_prior=
  if osascript -e "set volume output muted $prior" >/dev/null; then
    echo "output mute restored to $prior" >&2
  else
    echo "WARN output mute restore to $prior failed; restore it by hand" >&2
  fi
}

output_mute_guard_begin() {
  local prior
  prior=$(osascript -e 'output muted of (get volume settings)') || { echo 'FAIL output mute unreadable'; return 1; }
  [[ $prior == true || $prior == false ]] || { echo "FAIL output mute unreadable: $prior"; return 1; }
  output_mute_guard_prior=$prior
  trap output_mute_guard_restore EXIT
  trap 'output_mute_guard_restore; exit 130' INT
  trap 'output_mute_guard_restore; exit 143' TERM
  osascript -e 'set volume output muted true' >/dev/null || { echo 'FAIL output mute write'; return 1; }
  output_mute_guard_confirm || { echo 'FAIL output mute unconfirmed'; return 1; }
}

# Read-only: succeeds only while output is muted.
output_mute_guard_confirm() {
  [[ $(osascript -e 'output muted of (get volume settings)') == true ]]
}
