# UI mode: Rune or Swift (Phase 5b, R19)

This is a contract written before the Rune-child launcher exists, not evidence
that VoiceBar implements it. Run `bash formal/ui-mode-switch/check.sh`; record
with `python3 -B formal/check-model.py formal/ui-mode-switch --record`.
On this Mac put `/opt/homebrew/opt/openjdk/bin` first on PATH.

## State and ownership

| State | Meaning and intended owner |
| --- | --- |
| `pref` | Stored `VOICEBAR_UI` selection, Rune or Swift; the launch reader belongs in `flow-bar/Sources/VoiceBar/VoiceBarApp.swift`. Both initial selections are explored. |
| `mode` | The selection read once for this launch; unset only while down. Preference changes never update it in Fixed. |
| `app` | Down, launching, running, quitting: launch and termination gates in `VoiceBarApp.swift`. |
| `swiftUI` | None or live: **any** Swift window, panel, hosting view or view model counts as live, even if hidden. Future gating must precede the eager `VoiceState` allocation in `VoiceBarApp.swift`, not merely hide `FloatingPanel` (`flow-bar/Sources/VoiceBarUI/FloatingPanel.swift`). |
| `runeChild` | None, starting, live, crashed: the one owned Rune process, including the interval between spawn and ready. A future Rune supervisor must follow `flow-bar/Sources/VoiceBar/VoiceBarDaemonController.swift`; this is a proposed responsibility, no Rune supervisor exists yet. |
| `launchMode` | Ghost snapshot of the launch read, unchanged until down; witnesses mid-launch mode changes without relying on instrumentation in ChangePreference. |
| `runeCrashSeen` | Ghost history bit, retained until down: after a Rune exit, Swift must remain absent even after the child restarts. |

## Actions and fairness

`Launch` (also `Relaunch`) moves down to launching and snapshots `pref` in
`VoiceBarApp.swift`. `CreateSwiftUI` represents *all* UI allocation, including
view models, behind the Swift-only gate. `StartRuneChild` admits exactly one
child in Rune mode; `RuneChildReady` completes startup; `FinishLaunch` marks
the selected UI ready. Each is blocked once quitting begins.

`RuneChildCrash` and `RuneChildCleanExit` both mark unexpected termination for
restart. `RestartRuneChild` owns the delayed replacement. These are obligations
for the future Rune supervisor, using the controller's `launch`,
`terminationHandler`, `scheduleRestart`, `stopping` and duplicate-start guards
as the pattern. `VoiceBarDaemonLauncher.swift` is the simpler start/stop helper;
it does not provide the controller's restart policy. Neither file is changed.

`ChangePreference` toggles the persisted selection at any time, including
launching and quitting; only the next launch reads it. `Quit` shuts admission,
`StopRuneChild` acknowledges child termination, and `FinishQuit` reaches down
only after that acknowledgement and releases the Swift UI. This corresponds
to `VoiceBarApp.swift`'s termination path and the future Rune controller's stop
and exit-wait path. A late ready/restart event is refused after Quit.

Weak fairness applies to restart, ready, stop and finishing quit. A crashed
child cannot remain crashed by scheduler starvation: it restarts and becomes
live, or quitting completes. There is no fairness assumption forcing the user
to quit. Preference changes may continue forever and launch cycles are
unbounded; the state space is finite without bounding user events. The model
abstracts successful spawn/readiness and acknowledged termination; crashes are
modelled after ready, not an endless series of pre-ready startup failures.

## Properties and mutation proof

| Acceptance property | Meaning | Exact failing config |
| --- | --- | --- |
| `NeverBoth` | Swift objects and a starting/live Rune child never coexist. | `MutantHotSwitchBoth` |
| `InactiveNeverExists` | Rune mode has no Swift objects; Swift mode has no Rune child, even a crashed one. | `MutantSwiftAlwaysCreated` |
| `ModeSetOnce` | The active selection equals its launch snapshot until down. | `MutantHotSwitch` |
| `NoOrphanChild` | A down app has no owned child in any state. | `MutantNoStopOnQuit` |
| `NoFallbackDrawing` | After a Rune exit, Swift objects remain absent throughout that Rune launch. | `MutantLazySwiftFallback` |
| `CrashRecovers` | A Rune crash eventually reaches a live child or a down app. | `MutantLazySwiftFallbackStuck` |

There are **four fault variants**, as requested: HotSwitch applies preferences
while running without tearing down the old UI; LazySwiftFallback creates Swift
on a Rune exit and substitutes fallback for restart; NoStopOnQuit allows down
without stopping; SwiftAlwaysCreated allocates Swift regardless of selection.
Each requested mutant config isolates exactly its named property. Two extra
configs reuse HotSwitch and LazySwiftFallback to prove NeverBoth and
CrashRecovers respectively: the repository receipt gate requires a named
failing config for every acceptance property. They introduce no additional
fault variants. An isolated failing config does not claim that its fault could
violate no other property. Fixed checks all five invariants and the temporal
property together. `results/MUTANTS.md` and `results/run.json` record the gate;
`results/TIMING.md` retains Fixed's raw TLC count/time lines.

## Scope and remaining implementation gates

`checks.json` deliberately has an empty `sources` array: no product source is
bound or hashed yet. The runner hashes this spec, every config, the manifest
and shared runner helpers automatically. `sourceBaseline` names the starting
checkout only; it is not a product-conformance receipt.

This models event order, not pixels or elapsed backoff. It does not cover
drawing, the socket protocol, permissions, audio, native windows, PIDs or
cross-process ownership fencing, signing, app crashes/force-kill, spawn failure,
failed kill acknowledgement or cross-machine behaviour. A single child-valued
variable represents one owned process; it cannot prove real OS process counts.
The existing daemon controller suppresses activation/restart when disabled,
and can defer to another live daemon on clean exit. Those daemon-specific
policies are not a Rune UI shutdown policy and are not imported here. Recovery
assumes Rune supervision enabled and no external owner; a future disabled Rune
mode needs an explicit shutdown contract rather than quietly weakening liveness.
There is no native run, source projection or product conformance test in this
slice. The later launcher must prove allocation gates and supervision against
this contract, followed by real installed-app verification.
