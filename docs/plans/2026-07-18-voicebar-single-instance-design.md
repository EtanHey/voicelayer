# VoiceBar Canonical Single-Instance Design

## Decision

Normal-stack VoiceBar launches must converge on one process. The canonical
bundle at `/Applications/VoiceBar.app` always wins. When the canonical bundle
launches, it supersedes every older normal-stack VoiceBar instance by exact
PID before binding the resident socket. When a non-canonical bundle launches
while the canonical bundle is already running, the non-canonical launch exits.

Isolated QA launches remain outside the guard when they carry a socket-path
override. This preserves the hard resident/isolated fence and prevents a test
build from terminating the resident app.

## Rejected approaches

- Keep the current "new launch exits" guard: this leaves a stale resident alive
  during a canonical deploy.
- Kill by process name: `pkill VoiceBar` has no path provenance and can kill an
  isolated proof app.

## Components

- `VoiceBarInstanceGuard` is a pure planner over PID and resolved bundle path.
  It returns either bypass, exit-current, or a sorted list of exact duplicate
  PIDs to supersede.
- `AppDelegate` maps `NSRunningApplication` records into planner inputs. It
  gracefully terminates each planned application, waits briefly for that exact
  PID, and force-terminates only a still-live planned PID before startup
  continues.
- Unit tests cover canonical precedence, new-launch supersession,
  deterministic exact-PID selection, and isolated-socket bypass.

## Packaging law

This is the runtime half of X2 packaging-config §4: installed-copy equals
released-copy, the resident version stamp is verifiable, and only the canonical
`/Applications/VoiceBar.app` is allowed to own the normal-stack runtime.
