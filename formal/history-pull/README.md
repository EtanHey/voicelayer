# History pull-down and reversible open/close (2.3 lane U4)

Morph B (approved mock 2-morph / 5-history): History opens by the clock or by pulling the
notch down; every open/close is a spring on one progress value and reverses from wherever it
is. Order-of-events risks modelled here:

- **Drag versus click.** A press on the notch band stays a click until it moves the 3 pt slop
  (`NotchHistoryPull`). A click never moves the panel.
- **A close is never cut off.** The window keeps History's size (`isHistoryMounted`) until the
  close spring's own completion fires. 2.2.60 unmounted at once, so AppKit shrank the window
  under the closing shell (R0856-01/-11, "closes is worse").
- **Stale completions.** SwiftUI fires a superseded animation's completion too
  (`completionCriteria: .removed`); only the current generation may unmount, never while open is
  wanted or a pull holds the panel.
- **Cancelled drags.** A pull the system cancels (no `onEnded`) still settles at the nearer end
  (`@GestureState` reset → `endHistoryPull(cancelled: true)`).
- **Extend handle (V6).** A handle press inside the slop is a click and changes nothing; a
  released (or cancelled) handle springs to the nearer of two detents, collapsed 6 rows or
  expanded 8 (Etan, 2026-11-08: one pull goes 6 → 8, "it only adds one more row"), never resting
  anywhere else (`NoStrandedRows`); at rest the hit region holds exactly the rows drawn (`HitMatchesRows`),
  because the settled rows reach the presentation model on release. The band pull and the handle
  never own the pointer at once.
- **Cancelled presses and mid-flight grabs (Codex review R1).** A press the system cancels
  while still inside the slop ends like a click, so the next gesture never reuses its stale start
  (`NoStalePress`). A press that grabs a moving panel or rows continues from what is drawn
  (`NotchHistorySpringFlight`), never from the spring's target (`NoGrabJump`).
  Out of model scope: values past either end. The model's springs step monotonically between
  levels 0..N and never overshoot, so a grab during the open spring's overshoot (or an undershoot)
  isn't representable here. That hand-off (the drawn, out-of-range value carried as an offset with
  zero displacement) is proven by `NotchHistoryMorphTests.testAGrabDuringOvershootOrUndershootHasZeroDisplacement`
  (Codex review R2).
- **Reversible.** `Animate` never changes the level: a retarget springs from where it is.
  This holds by construction in the spec (and in SwiftUI interpolating springs, which merge
  velocity on retarget).

Run: `bash formal/history-pull/check.sh` (needs a JDK on PATH, e.g.
`PATH=/opt/homebrew/opt/openjdk/bin:$PATH`).

| Config | Expected | Result (2026-11-08, M1, OpenJDK 27; earlier rows unchanged since 2026-11-05) |
| --- | --- | --- |
| Fixed | PASS | 899 distinct states (two detents) |
| Old (2.2.60: close unmounts at once) | `NoClippedPanel` fails | violated, 19 states |
| MutantNoGeneration (any completion unmounts) | `NoClippedPanel` fails | violated, 104 states |
| MutantNoSlop (a press moves before the slop) | `ClickNeverMoves` fails | violated, 7 states |
| MutantNoCancel (a cancelled drag is dropped) | `NoStrandedPanel` fails | violated, 32 states |
| MutantNoSnap (a released handle stays between rows) | `NoStrandedRows` fails | violated, 474 states |
| MutantWholeRow (the pre-11-08 snap to any whole row: a pull stops at 7) | `NoStrandedRows` fails | violated, 714 states |
| MutantNoPublish (settled rows never reach the hit region) | `HitMatchesRows` fails | violated, 705 states |
| MutantNoPendingCancel (a press cancelled inside the slop stays pending) | `NoStalePress` fails | violated, 11 states |
| MutantSeedFromTarget (a grab mid-spring starts from the target) | `NoGrabJump` fails | violated, 15 states |

Swift guards: `NotchHistoryMorphTests` (pull state machine, release target, rubber band,
spring values, handle hit strip, rows rubber band and two-detent snap, hit region = settled rows, session height), `NotchShellCentredTests.testTheOpenHistoryPanelIsOneFlushShapeWithFlaredTopCorners`.
The live drag on the real notch (pointer capture across the panel edge, `isHistoryPullActive`)
is the native XCUI `U4NotchHistoryNativeTests` (pointer events: run on the M1 test rig).
