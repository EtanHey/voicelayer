#!/usr/bin/env bash
# Mute the host output for one run and always put back the state that was found.
#
# AIDEV-NOTE (MUTE1, 2026-10-19): Etan found his Mac muted and had not muted it.
# The UIE2E runner used to mute and deliberately leave output muted, relying on
# every operator to restore it by hand. Never mute without this guard.
#
# Sourceable and side-effect free: sourcing touches no audio state. The first
# output_mute_guard_begin records the prior state, installs EXIT, INT and TERM
# traps that restore it (with a bounded retry), and only then mutes; a later begin
# keeps that first state. The restore runs on success,
# failure and interrupt. SIGKILL cannot be trapped. A caller that needs its own
# EXIT trap must call output_mute_guard_final from it (restore is idempotent).

# Re-sourcing keeps an active guard's saved state.
output_mute_guard_prior=${output_mute_guard_prior:-}

# Clears the saved state only after the restore is read back; returns nonzero otherwise.
output_mute_guard_restore() {
  [[ -n $output_mute_guard_prior ]] || return 0
  if osascript -e "set volume output muted $output_mute_guard_prior" >/dev/null &&
    [[ $(osascript -e 'output muted of (get volume settings)') == "$output_mute_guard_prior" ]]; then
    echo "output mute restored to $output_mute_guard_prior" >&2
    output_mute_guard_prior=
    return 0
  fi
  echo "WARN output mute restore to $output_mute_guard_prior failed" >&2
  return 1
}

# Final cleanup from the traps: a bounded retry, so one transient failure is recoverable.
output_mute_guard_final() {
  for _ in 1 2 3; do
    output_mute_guard_restore && return 0
    sleep 0.2
  done
  echo "FAIL output mute not restored to $output_mute_guard_prior; restore it by hand" >&2
  return 1
}

output_mute_guard_begin() {
  # A second begin keeps the first saved state; capturing again would save the guard's own mute.
  if [[ -z $output_mute_guard_prior ]]; then
    local prior
    prior=$(osascript -e 'output muted of (get volume settings)') || { echo 'FAIL output mute unreadable'; return 1; }
    [[ $prior == true || $prior == false ]] || { echo "FAIL output mute unreadable: $prior"; return 1; }
    output_mute_guard_prior=$prior
    trap output_mute_guard_final EXIT
    trap 'output_mute_guard_final; exit 130' INT
    trap 'output_mute_guard_final; exit 143' TERM
  fi
  osascript -e 'set volume output muted true' >/dev/null || { echo 'FAIL output mute write'; return 1; }
  output_mute_guard_confirm || { echo 'FAIL output mute unconfirmed'; return 1; }
}

# Read-only: succeeds only while output is muted.
output_mute_guard_confirm() {
  [[ $(osascript -e 'output muted of (get volume settings)') == true ]]
}
