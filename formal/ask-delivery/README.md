# Caller-bound Ask delivery

Models `src/ask-delivery.ts`: an interrupted `voice_ask` reaches its original caller on that caller's
next voice call. This is recovery on the next call, not automatic delivery to an idle agent.

Actors: the caller's calls, its interrupt (a steer cancelling the tool call, whether or not the daemon
receives the cancellation), the capture flow (archive, finalize), the original response write, claim on
the next call, explicit ack, bridge-daemon reconnect and daemon crash. Rows are durable; wires, waiting
calls and daemon requests are lost on reconnect or crash.

Identity is the bridge's random capability. A restarted bridge is another caller with no binding to the
old rows, so `NoCrossCallerDelivery` also covers fail-closed restarts. clientInfo, cwd and request ids
carry no identity and are not modelled.

| Property | Meaning | Failing mutant |
| --- | --- | --- |
| `NoCrossCallerDelivery` | No caller reads another caller's Ask | `ScopeLeak`: recovery not keyed by the capability |
| `NoLossBeforeAck` | Only a delivery the owner read can be acked; a captured Ask is never dropped | `DeleteOnWrite`: a response write counts as delivery; `CrashDrops`: a crash voids a captured pending Ask |
| `NoDoubleInboxInsertion` | Every at-least-once copy carries one delivery id | `NewIdPerClaim`: each recovery mints a new id |
| `NoNewCaptureWhileRecovering` | No second capture while an earlier Ask is unacknowledged | `AdmitWhilePending`: a retried Ask opens a second capture |

`Recovery` checks all four with two callers, two operations, three calls per caller, one crash and one
reconnect. Liveness (an answered Ask eventually reaches a caller that keeps calling) is not checked:
it needs fairness on a client that may never call again, which is exactly the automatic-wake gap.

Record receipts with
`PATH=/opt/homebrew/opt/openjdk/bin:$PATH python3 -B formal/check-model.py formal/ask-delivery --record`.
