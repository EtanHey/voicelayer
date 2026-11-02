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
