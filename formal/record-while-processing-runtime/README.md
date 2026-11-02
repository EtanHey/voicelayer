# Runtime ownership refinement

This supplements Lane G's ENABLED/action-contract model, preserving its full
property and mutant set. `check.sh` uses the shared pinned TLC runner. The root
record-while-processing/check.sh runs all three modules and prints the complete
[union table](../record-while-processing/results/UNION-MUTANTS.md).

The runtime model distinguishes recorder drain, queued capture, decode, delivery
acknowledgement, terminal failure and target identity. Escape selects the mic
owner, otherwise the newest processing take. An undisplayed newest take requires
its own guard/cooldown. A stale guard eventually clears. An F5 during drain admits B immediately into a waiting capture intent. Its take ID,
target and early Stop/Cancel belong to B; A retains the physical microphone until
release is proven. Archive releases the microphone and StartQueued opens B once.
N6StartsB requires both drain admission and the enabled start after proven release;
QueuedCaptureStarts requires eventual start or explicit cancellation/failure.
RejectDrainMutant kills the former Busy refusal; StallQueuedAdmissionMutant and
StallQueuedProgressMutant kill a silently stranded intent. DrainRequestVisible
now requires admitted waiting state rather than a rejection notice. Failed exits
require a separate exit proof before another recorder can open. No fairness of
that proof is assumed. Capture failure leaves terminal failed, never recording.
Delivery requires the captured frontmost app. A readable captured AX window/element
must still match. When AX identity was unreadable at capture, the same captured
app PID/bundle with no other recording is the permitted fallback; unreadability
alone is not a target change. This fallback cannot deliver while B records.
UnreadableIdentitySingleTakeDelivers makes the single-take fallback available;
UnreadableRefusalMutant kills over-refusal and UnreadableOverlapMutant kills unsafe
fallback during B. RetargetMutant still kills a readable identity mismatch.
Legacy clients do not wait for ACK. Capable clients release the FIFO after ACK
or the bounded timeout, recording an unverified result. ProcessingSettles assumes
fair decoder/clock/timeout work, without assuming an ACK ever arrives.

The checked-in corpus exports every distinct actual cancellation context from
Fixed (excluding retained-event self edges). LaneIFormalConformanceTests replays
these against the real Swift router/VoiceState by default. Main conformance also
replays both historical and Fixed socket contexts against the real owned queue.
Focused fixture tests exercise actual timeout, failure and delivery outcome
persistence; models alone do not prove filesystem or installed-app behavior.

## Drain-window source refinement (FIXED-SUITE2)

The main model's `N6StartsB` covers the free-mic processing overlap. This module's
`N6StartsB` extends that contract to the physical drain interval: B is admitted
as a waiting intent immediately, without opening two recorders. `captureReleased`
represents an exit proof, not an idle UI projection. A failed capture alone never
provides that proof. Waiting includes the short dispatch/open interval, with Stop
remembered until B's authoritative mic-open receipt. Escape/X cancel that B intent.

| Action | Real code |
| --- | --- |
| DrainPress / N6StartsB | `VoiceBarCommandRouter.swift:136`, `:165`; `VoiceState.swift:2674` |
| Archive / ProveExit / StartQueued | `VoiceState.swift:2775`, `:2750`; blocked snapshots return before dispatch |
| Record dispatch / identity | `VoiceState.swift:2740`; original ID and captured target survive the wait |
| Stop before mic-open | `VoiceState.swift:1992`, `:2763` |
| Cancel waiting B / Escape | `VoiceState.swift:2076`; `VoiceBarCommandRouter.swift:91` |
| Reconnect custody | `VoiceState.swift:3530` |

The generated corpus includes drain admission and waiting cancellation edges.
The replay creates local waiting intents through the real F5 router; it never
invents daemon-owned waiting jobs. It advances A to each exported terminal or
processing phase and checks B's local cancellation or dispatched scoped cancel.
The existing non-waiting cancellation corpus continues to run in full. Focused
ownership fixtures check early release, exact-once replay, target custody, failure
proof, reconnect, and source/behavioral guards against the former refusal text.
