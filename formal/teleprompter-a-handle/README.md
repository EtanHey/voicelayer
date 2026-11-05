# U5 follow-up: Teleprompter A handle against the notch hit region

Run `python3 formal/check-model.py formal/teleprompter-a-handle`. Add `--record` only to refresh the committed evidence.

The handle sits at the bottom of the drawn lines. The panel passes clicks through outside the hit region unless a pull holds the pointer. The handle has its own hold (`setTeleprompterHandlePullActive`), separate from History's (`setHistoryPullActive`); the panel captures while either is held (`isPointerHeldByPull`). The canvas always reserves eight lines (`restingLowerSurfaceHeight`), so the window never resizes under the pointer. That leaves two hazards: the hit region against the lines drawn, and a hold that outlives its drag.

| Config | Result | What breaks |
| --- | --- | --- |
| Fixed | PASS | n/a |
| AsyncReleaseMutant | FAIL HandleReachable | the hit region waits for the app's async panel refresh: grow, release, and the handle sits outside it |
| ShrinkReleaseMutant | FAIL NoDeadBand | same, shrinking: the hit region still claims lines no longer drawn |
| CancelLeakMutant | FAIL NoStuckHold | the hold is released only in `onEnded`; a cancelled gesture or an unmounted handle never delivers it, so the transparent 8-line reserve keeps swallowing clicks (review R1 on #738) |
| SharedHoldMutant | FAIL HistoryHoldKept | the handle releases a shared flag and drops a hold History owns |

Mapping:
- `Step` is `onVisibleLinesChange` in BarView. It sets `state.teleprompterVisibleLines` and calls `presentationModel.setTeleprompterLines` in the same call, as U4's `setHistoryRows` does.
- `Sync` is `VoiceState.didSet → onPanelLayoutChange → setTeleprompterLines`, which arrives later and changes nothing.
- `Release` is `onEnded` → `releasePointer()`.
- `Cancel` is SwiftUI dropping `onEnded`. The view releases on its `@GestureState` reset and on the handle's `onDisappear`, with a BarView backstop when the teleprompter body unmounts. `releasePointer()` is idempotent and owner-checked (`ownsPointer`).
- `HistoryPress`/`HistoryRelease` is U4's pull and its own flag.
