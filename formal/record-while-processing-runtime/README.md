# Runtime ownership refinement

This supplements Lane G's ENABLED/action-contract model, preserving its full
property and mutant set. `check.sh` uses the shared pinned TLC runner. The root
record-while-processing/check.sh runs all three modules and prints the complete
[union table](../record-while-processing/results/UNION-MUTANTS.md).

The runtime model distinguishes recorder drain, queued capture, decode, delivery
acknowledgement, terminal failure and target identity. Escape selects the mic
owner, otherwise the newest processing take. An undisplayed newest take requires
its own guard/cooldown. A stale guard eventually clears. An F5 during drain has
an observable rejection. Capture failure leaves terminal failed, never recording.
Delivery requires the captured target identity; it cannot steal focus from B.
Legacy clients do not wait for ACK. Capable clients release the FIFO after ACK
or the bounded timeout, recording an unverified result. ProcessingSettles assumes
fair decoder/clock/timeout work, without assuming an ACK ever arrives.

The checked-in corpus exports every distinct actual cancellation context from
Fixed (excluding retained-event self edges). LaneIFormalConformanceTests replays
these against the real Swift router/VoiceState by default. Main conformance also
replays both historical and Fixed socket contexts against the real owned queue.
Focused fixture tests exercise actual timeout, failure and delivery outcome
persistence; models alone do not prove filesystem or installed-app behavior.
