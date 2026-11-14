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

`RuneChildCrash` and `RuneChildCleanExit` both mark unexpected termination
while starting or live for restart. `RestartRuneChild` owns the delayed
replacement. These are obligations
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

Weak fairness applies to restart, ready, stop and finishing quit. Under `Spec`
alone, `CrashRestarts` holds: every crashed Rune child eventually returns to
starting, or the app reaches down. There is no assumption forcing the user to
quit. `Fixed.cfg` checks this obligation and all seven safety invariants.
Preference changes may continue forever and launch cycles are unbounded; the
state space is finite without bounding user events.

Weak fairness of ready does **not** guarantee a live child: startup crashes may
interrupt every starting interval, so ready is never continuously enabled.
`HealthyChildSpec` explicitly adds the **environment assumption**
`SF_vars(RuneChildReady)`: a child started again and again eventually comes up.
`FixedHealthyChild.cfg` checks both `CrashRestarts` and `CrashRecovers` under
that assumption, with the same safety invariants. This is not an unconditional
application recovery promise, nor a bounded startup deadline.
`MutantUnhealthyChild.cfg` retains the startup-crash counterexample under the
ordinary `Spec`, with the **Fixed** implementation. It is an assumption-removal
negative control registered as a mutant for the receipt gate, not a faulty
implementation. Its cycle remains launching and alternates starting/crashed.

In a launch crash loop nothing is drawn: Rune never comes up, Swift objects
remain absent, and the app keeps restarting the child. `LaunchingNeverDrawsSwift`
states this safety requirement explicitly even though `InactiveNeverExists`
implies it. Open product question for the lead: where would a visible
"Rune UI failed to start" notice come from Swift **without creating the Swift
UI**? No notice or exception to the allocation rule is modelled here.

`StopRuneChild` accepts every non-none child state, including starting and
crashed. Weak fairness then completes stopping and quit. `NoRestartAfterQuit`
checks the stronger admission condition that neither start nor restart is
**enabled** while quitting; an already-starting child may remain starting
until stopped. Ready is also gated by `Active`. This is not a requirement to
clear the child atomically in the Quit action.

## Properties and mutation proof

| Acceptance property | Meaning | Exact failing config |
| --- | --- | --- |
| `NeverBoth` | Swift objects and a starting/live Rune child never coexist. | `MutantHotSwitchBoth` |
| `InactiveNeverExists` | Rune mode has no Swift objects; Swift mode has no Rune child, even a crashed one. | `MutantSwiftAlwaysCreated` |
| `ModeSetOnce` | The active selection equals its launch snapshot until down. | `MutantHotSwitch` |
| `NoOrphanChild` | A down app has no owned child in any state. | `MutantNoStopOnQuit` |
| `NoFallbackDrawing` | After a Rune exit, Swift objects remain absent throughout that Rune launch. | `MutantLazySwiftFallback` |
| `LaunchingNeverDrawsSwift` | A Rune launch allocates no Swift UI, including during a startup crash loop. | `MutantLaunchingDrawsSwift` |
| `NoRestartAfterQuit` | Start and restart admission is closed while quitting. | `MutantRestartDuringQuit` |
| `CrashRestarts` | Under weak fairness, a Rune crash eventually reaches starting or down. | `MutantGiveUpAfterCrash` |
| `CrashRecovers` | Under the healthy-child environment assumption, a Rune crash eventually reaches live or down. | `MutantLazySwiftFallbackStuck`, `MutantUnhealthyChild` (assumption removed) |

The four original fault variants remain: HotSwitch applies preferences while
running without tearing down the old UI; LazySwiftFallback creates Swift on an
exit and suppresses restart; NoStopOnQuit allows down without stopping;
SwiftAlwaysCreated allocates Swift regardless of selection. The six original
configs still fail on exactly their original named properties.
`MutantLazySwiftFallbackStuck` now uses `HealthyChildSpec`, retaining its
`CrashRecovers` target: readiness fairness cannot help a child never restarted.

Two new fault variants are GiveUpAfterCrash (suppresses restart without drawing
Swift, violating `CrashRestarts`) and RestartDuringQuit (admits restart after
Quit, violating `NoRestartAfterQuit`). `MutantLaunchingDrawsSwift` reuses
SwiftAlwaysCreated to isolate the explicit launch invariant. With the
assumption-removal control there are two positive configs and ten negative
configs. Each negative config checks exactly one named property; it does not
claim that its fault could violate no other property. `results/MUTANTS.md` and
`results/run.json` record the gate; `results/TIMING.md` retains the positive
configs' raw TLC count/time lines.

## Scope and remaining implementation gates

`checks.json` deliberately has an empty `sources` array: no product source is
bound or hashed yet. The runner hashes this spec, every config, the manifest
and shared runner helpers automatically. `sourceBaseline` names the starting
checkout only; it is not a product-conformance receipt.

This models event order, not pixels or elapsed backoff. It does not cover
drawing, the socket protocol, permissions, audio, native windows, PIDs or
cross-process ownership fencing, signing, app crashes/force-kill, OS spawn-call
failure,
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
