# G4b gate callback audit

Scope: production `src/` callers of `withUpdateGateLock`, `safeGateLock`,
`updateVoiceGate` and `acknowledgeVoiceDrain`, including installer, bootstrap,
participant, admission and storage helpers. Tests supply additional deliberately
throwing callbacks to prove the boundaries.

The table records whether an **expected participant-evidence failure can escape
into G1**. "Yes (fixed)" identifies the corrected boundary. Unexpected storage
persistence failures retain their existing fail-closed behavior.

| Callback/site | Can throw for expected evidence failure | Result |
| --- | --- | --- |
| installer harness verify | no | safeParticipantProof returns false |
| installer runGatedInstall verify | yes (fixed) | catches participant.verify and returns false |
| installer transition confirm, REQUEST/PREPARE/COMMIT | no | calls safe verify; controller persistence still fails closed on unexpected I/O |
| installer cancelLease -> updateVoiceGate | no | no proof callback supplied |
| installer acknowledgeVoiceDrain verify | yes (fixed) | same safe verify wrapper |
| bootstrap participant.verify | yes (fixed) | cached boolean and timestamp only; launchctl/pgrep sampling outside G1 |
| bootstrap cleanup -> withUpdateGateLock | yes (fixed) | catches unreadable/malformed evidence, returns refusal; deletion I/O still fails closed |
| installer participant verify | no | memory/lease comparison and production performance.now only |
| installer participant quit-authorization ACK proof | no | COMMITTED predicate and memory-only verify |
| installer participant exit-observation ACK proof | no | COMMITTED predicate only |
| native drain/quit proof, both ACK calls | yes (fixed) | catches readiness exception, returns false |
| storage readInstallerGateState -> withUpdateGateLock | no | diagnostic/read/parser evidence returns UNKNOWN; mkdir contention propagates for bounded retry outside G1 |
| storage applyUpdateGateCommand proof wrapper | yes (fixed) | catches caller proof exception, returns false; G2 persistence stays outside wrapper |
| G2 safeGateLock -> withUpdateGateLock wrapper | no (at G1 boundary) | inner body errors caught and diagnosed; unsavable fault marker intentionally retains lock |
| G2 initializeSupervisedVoiceGate exclusive initializer | no for expected evidence failures | existence/read errors return false; unexpected initialization persistence is owned by safeGateLock |
| G2 initializeVoiceGate path-fault sentinel | no (at G1 boundary) | deliberate sentinel caught inside safeGateLock; not participant evidence |
| G2 initializeVoiceGate initial initializeUnderLock | no (at G1 boundary) | storage errors caught by safeGateLock; unsavable fault intentionally retains lock |
| G2 initializeVoiceGate retry fallback initializeUnderLock | no (at G1 boundary) | same |
| G2 acquire path-fault sentinel | no (at G1 boundary) | deliberate sentinel caught inside safeGateLock |
| G2 acquire body, normal/retry invocation | no (at G1 boundary) | absent snapshot returns unregistered; safeGateLock owns unexpected storage faults |
| G2 admission release -> withUpdateGateLock | no | read/unlink errors caught, diagnosed, return false |
| G2 updateVoiceGate -> safeGateLock body | no for audited production proofs | snapshot returns null; all production proofs above total; storage persistence unchanged |
| G2 acknowledgeVoiceDrain -> safeGateLock body | no for audited production proofs | snapshot returns null; all production proofs above total |


The G2 path-fault sentinels deliberately throw inside the inner body. They are
caught by `safeGateLock` inside G1; they are not participant proofs. Initialization
and acquisition bodies can also throw on storage faults. `safeGateLock` preserves
the existing diagnostic behavior, including retaining the lock if fault evidence
cannot be saved. These unchanged nested exceptions are not claimed to be removed.

The installer's COMMIT proof may throw from `persistInstallerController` on an
unexpected persistence error. G2 gate persistence and bootstrap cleanup deletion
can also throw. No catch around these writes turns uncertain storage into valid
participant evidence. `withUpdateGateLock` still retains its lock on arbitrary
uncaught callbacks and asynchronous callbacks.

## Durable COMMIT ordering

When COMMIT returns an APPLIED COMMITTED result, `runGatedInstall` synchronously
forbids rollback and notifies bootstrap before returning to its acquisition
wrapper. It then reads persisted state through an acquired G1 snapshot, retrying failed
acquisition outside the lock.
A matching COMMITTED lease records the confirmed outcome. An unavailable or
mismatched readback retains the rollback prohibition and requires recovery.
Expected readback faults never fabricate OPEN. A separate UNKNOWN observation
and lock-presence probe are not used to classify contention.

The live participant and bootstrap acquisition wrappers read persisted state after
acquisition, retrying only bounded lock contention outside G1. A matching
COMMITTED lease returns without post-sampling. UNKNOWN or a mismatched committed
lease refuses immediately; it never becomes permission to sample or restore.
Postcommit validation runs in the installer's separate refresh/quit phase.

If a later postcommit check fails, the installer writes a recovery receipt and
retains closed admission. Independently, bootstrap reads persisted state before
its finalizer: only proven OPEN can permit precommit gate cleanup, legacy
enablement or job reload. Restoring the observed VoiceBar bundle for voice
availability remains separate from restoring legacy launchd state.

## Reproducible verification

`src/__tests__/update-gate-proof-failure.test.ts` supplies throwing installer,
native-readiness and compatibility proofs. Each refuses without a leftover lock
or poisoned diagnostic and permits Cancel to restore OPEN. It also makes an
adversarial acquisition wrapper throw immediately after durable COMMIT and checks
that the exact postcommit recovery receipt is written, without quit or install.

`src/__tests__/update-gate-bootstrap.test.ts` injects a one-shot process-sample
failure only after the gate contains COMMITTED. It checks COMMITTED and controller
custody, a postcommit recovery receipt, no legacy enable/bootstrap, no install and
no leftover G1 or supervisor mutex. The real live-participant wrapper additionally proves no identity sampler runs
after its durable COMMIT write. Both durable-COMMIT tests failed before the
ordering fix: installer attempted precommit Cancel, and bootstrap re-enabled and
reloaded both legacy services.

Run with the repository preload intact:

```bash
bun test src/__tests__/update-gate-proof-failure.test.ts src/__tests__/update-gate-bootstrap.test.ts
```
