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
  released (or cancelled) handle springs to a whole row, never resting between rows
  (`NoStrandedRows`); at rest the hit region holds exactly the rows drawn (`HitMatchesRows`),
  because the settled rows reach the presentation model on release. The band pull and the handle
  never own the pointer at once.
- **Reversible.** `Animate` never changes the level: a retarget springs from where it is.
  This holds by construction in the spec (and in SwiftUI interpolating springs, which merge
  velocity on retarget).

Run: `bash formal/history-pull/check.sh` (needs a JDK on PATH, e.g.
`PATH=/opt/homebrew/opt/openjdk/bin:$PATH`).

| Config | Expected | Result (2026-11-05, M4, OpenJDK 21) |
| --- | --- | --- |
| Fixed | PASS | 1236 distinct states |
| Old (2.2.60: close unmounts at once) | `NoClippedPanel` fails | violated, 23 states |
| MutantNoGeneration (any completion unmounts) | `NoClippedPanel` fails | violated, 125 states |
| MutantNoSlop (a press moves before the slop) | `ClickNeverMoves` fails | violated, 7 states |
| MutantNoCancel (a cancelled pull is dropped) | `NoStrandedPanel` fails | violated, 36 states |
| MutantNoSnap (a released handle stays between rows) | `NoStrandedRows` fails | violated, 448 states |
| MutantNoPublish (settled rows never reach the hit region) | `HitMatchesRows` fails | violated, 605 states |

Swift guards: `NotchHistoryMorphTests` (pull state machine, release target, rubber band,
spring values, handle hit strip, rows rubber band and snap, hit region = settled rows, session height), `NotchShellCentredTests.testTheOpenHistoryPanelIsOneFlushShapeWithFlaredTopCorners`.
The live drag on the real notch (pointer capture across the panel edge, `isHistoryPullActive`)
is the native XCUI `U4NotchHistoryNativeTests` (pointer events: run on the M1 test rig).
