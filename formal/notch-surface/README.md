# Notch surface: one owner for every drawer (2.4 Lane A)

The notch shows the recording wings and the teleprompter, and two drawers hang from it: History and, new in
2.4, Settings. In 2.3 History's open state was a SwiftUI flag in `BarView`, its dismissal monitors only knew
History, and Settings was a separate window. `NotchSurfaceMachine` (`flow-bar/Sources/VoiceBarUI/NotchSurface.swift`)
now decides every present and dismiss; `BarView`, the dismissal monitors (`NotchDrawerDismissal`), the gear, the
pull gesture and the modal observer only send it events.

The model keeps the two drawers as two flags, the shape 2.3 had, so each invariant states what the single machine
guarantees that loose flags did not. History's detent (6 or 8 rows) and Settings' tab refine those flags and never
change which drawer is open, so they are abstracted; `NotchSurfaceMachineTests` walks the Swift machine with them
(40 states) and checks that its projection onto these variables is exactly TLC's 12 states.

Run: `bash formal/notch-surface/check.sh`. Record evidence: `python3 -B formal/check-model.py formal/notch-surface --record`.

| Property | Bug it prevents | Failing mutant |
| --- | --- | --- |
| `AtMostOneDrawer` | Settings drawn over a still-open History | `MutantNoExclusive`: opening one drawer leaves the other's flag |
| `DismissalReachable` | a drawer with no way out (2.3's monitors were History-only; NATIVE-U4's Esc closed nothing) | `MutantHistoryOnlyDismiss` |
| `DrawerAlwaysClosable` (temporal) | a drawer wedged open forever | `MutantHistoryOnlyDismissStuck` |
| `DrawerReachableWhileCapturing` | Etan, QA 0510 N7: History and Settings could not be opened while recording (R3: "as long as there's no teleprompter of speech or asking, settings and history should be pulled down") | `MutantRecordingRefusesDrawer`: the 2.4 guard refuses an open while recording |
| `CaptureKeepsDrawer` | Etan, QA 0510 N8: starting a capture closed the open drawer | `MutantRecordingClosesDrawer`: the 2.4 capture closes it (ghost flag `captureClosedDrawer`) |
| `NoDrawerOverModal` | a drawer over a Settings sheet or alert, taking its clicks | `MutantNoModalGuard` (no open guard, sheet keeps the drawer) |
| `NoDrawerOverTeleprompter` | a drawer over a read-aloud's teleprompter | `MutantTeleprompterKeepsDrawer` |

Swift guards: `NotchSurfaceMachineTests` (every transition, every refusal, the exhaustive walk and projection),
`NotchDrawerDismissalTests` (outside click on VoiceBar's own Settings window, Esc whichever window is key, sheets keep
their Esc, the modal observer), `NotchSurfaceHostedFlowTests` (the real BarView in the real panel: History toggle,
drag up closes, pulling further down opens Settings, the gear, a drawer kept and opened during recording).
