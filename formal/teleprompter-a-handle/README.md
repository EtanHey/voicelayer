# U5 follow-up: Teleprompter A handle against the notch hit region

Run `python3 formal/check-model.py formal/teleprompter-a-handle`. Add `--record` only to refresh the committed evidence.

The handle sits at the bottom of the drawn lines. The panel passes clicks through outside the hit region unless a pull holds the pointer (`setHistoryPullActive`, U4's pull flag, reused). The canvas always reserves eight lines (`restingLowerSurfaceHeight`), so the window never resizes under the pointer. That leaves one race: the hit region against the lines drawn.

| Config | Result | What breaks |
| --- | --- | --- |
| Fixed | PASS | n/a |
| AsyncReleaseMutant | FAIL HandleReachable | the hit region waits for the app's async panel refresh: grow, release, and the handle sits outside it |
| ShrinkReleaseMutant | FAIL NoDeadBand | same, shrinking: the hit region still claims lines no longer drawn |

Mapping:
- `Step` is `onVisibleLinesChange` in BarView. It sets `state.teleprompterVisibleLines` and calls `presentationModel.setTeleprompterLines` in the same call, as U4's `setHistoryRows` does.
- `Sync` is `VoiceState.didSet → onPanelLayoutChange → setTeleprompterLines`, which arrives later and changes nothing.
- `Release` is `onHandleDrag(false)`.
