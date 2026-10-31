# Daemon/CLI update admission (G2)

Voice availability and update authorization deliberately differ. AGENTS.md says **"a fix that loses my words is worse than the bug"**. A missing gate must not disable dictation. Daemon/standalone/stdio startup and first voice admission exclusively create an absent OPEN generation-0 record and private 0700 `<gatePath>.admissions` directory under G1's lock. Creation never replaces an existing record or repairs a malformed one.

For malformed/contradictory existing gate data, voice remains available: it admits unregistered, emits a loud fixed diagnostic, and exclusively creates `<gatePath>.voice-diag.json`. The original gate bytes stay intact. Updater requests/acknowledgements refuse UNKNOWN for missing, malformed, contradictory or diagnostic-marked evidence; updater calls never bootstrap. A verified recovery must reconcile evidence and clear diagnostics. Valid DRAINING/PREPARED/COMMITTED gates with a real admissions directory and no fault evidence still refuse new voice work with UPDATE_BUSY. Missing or unsafe closed-gate ledgers diagnose and admit voice unregistered; they are never recreated on that path.

Known degraded/diagnostic evidence bypasses the lock before any attempt. Fresh capture ingress (socket record, Ask/converse, waitForInput and direct buffer capture) has a 20 ms async contention budget; other async admissions may retry for 1.5 seconds. Pending admissions carry a capture/speech kind: explicit socket Stop/Cancel cancel both pending kinds, while playback Stop cancels only pending speech. Playback Stop still reports only whether preparation/playback was stopped; selection Next on the last item does not cancel a pending capture. Synchronous media boundaries spin for at most 2 ms without sleeping before marking a real unregistered admission fault. Startup bootstrap starts only after VoiceBar connection setup (and MCP listener/stdio server.connect), detached with a 1.5-second async contention budget. Updater/ack polling collisions refuse without writing diagnostics: a live lock holder is not fault evidence. Exhausted contention (including a stale lock), bootstrap/registration/persistence failure or other gate fault admits voice unregistered and marks UNKNOWN; only a successfully observed closed gate returns UPDATE_BUSY. Diagnostics preserve the first-seen timestamp/pid and log at most once per minute per path. Diagnostic-file creation failure attempts a directory refusal marker; the process also retains UNKNOWN in memory. Recovery must reconcile evidence and restart the participant. Updater faults return REFUSED/UNKNOWN (acknowledgements return null), including lock contention and throwing proofs. Adapter bodies release G1’s lock after a fault only when a diagnostic file/directory positively exists; if both marker forms fail, the lock is retained as the evidence while voice still fails open. G1 observers also treat diagnostic entries as UNKNOWN. Only owned staging files are cleaned, and an unremovable lock remains refusal evidence. Release retries only its own record with exponential backoff for the process lifetime. Ownership mismatches return failure under the lock rather than throwing and orphaning it. Non-contention release failures preserve the record for recovery. No code reaps another owner's lock or registration.

Registered operations have 0600 JSON ledger records `{token,pid,incarnation,generation}`. Degraded voice has no ledger record. Write-and-rename provides cross-process visibility; ledger registration/release never does F_FULLFSYNC on the capture path. Gate-state transitions reuse G1's fsync/rename/parent-fsync/F_FULLFSYNC writer; bootstrap uses its exclusive hard-link publication mode with the same sync barriers. The lock remains G1's nonrecursive mkdir. The preload forces every path into its run root.

Only an operation's own archives can delay its admission release. Transient failed writes share one retry driver per archive, with exponential backoff capped at one second until durable or dropped; successful retries immediately release the original waiters. A deterministic dropped write affects its own archive, not future/unrelated operations. Physical exit uncertainty still retains admission. Ask spans prompt→capture→answer; queued selections carry required admission scopes through preparation, start and cancellation. Stop/Cancel, mute, silent think, paused replay/restart and admitted Next remain usable during drain. Historical replay/readback is new work and is gated before acknowledgement. MCP replay launches VoiceBar inside admission. Concurrent same-selection requests recheck identity after admission and duplicate arrivals are no-ops.

Trusted updater API: `updateVoiceGate(REQUEST|CANCEL)`, `acknowledgeVoiceDrain(lease, proof)`, and `updateVoiceGate(PREPARE|COMMIT, proof)`. The old storage `applyUpdateGateCommand` routes to this same admission-aware path; there is no second exported command implementation that skips the ledger. Prepare/commit recheck the empty ledger and current synchronous participant/target proof under the lock. Mutate only on APPLIED COMMIT; UNCHANGED never repeats installation. Missing proof refuses UNKNOWN; persisted preparation is insufficient.

G3/G4 must supply live native/daemon identity, pending-handoff, archive-durability, competing-owner and staged-target probes. Never accept those assertions from unauthenticated clients. Drain never writes Stop/Cancel signals.

Surface sweep: entry points cover MCP speak/ask/converse, raw socket speech/record/retranscription/previews, CLI fallback and exported media boundaries. Shared handlers cover daemon/standalone/stdio; admission precedes backend selection. Focused tests exercise fresh/corrupt state, lock races, retries, teardown, archive isolation and controls. Touched-area suites cover existing capture/playback/ingress contracts. Native F5/History/quit, Swift/Bun runtime parity, installer/cask integration and installed-app/agent proof remain lead/G3/G4 qualification. Harness latency is not real-app onset proof. No app build/install or live gate/socket operation was performed in this lane.

## Known gaps → G3 contract

These are G3 entry criteria, not fixes implemented in G2d. The updater remains NOT_GREEN for replacement until the native/updater protocol proves them across processes.

- **Commit race (SHOULD-FIX 3 / Macroscope :75):** APPLIED COMMIT alone does not authorize quit, unload or replacement. Before the first mutation, wait a short, explicitly specified grace period, then re-check diagnostic entries, the admission ledger and participant identity/acknowledgements. Any new marker/record or missing/contradictory evidence aborts the swap and enters recovery. G3 must supply a serialized abort/authorization handshake and a race test so a fail-open admission after the initial snapshot cannot be missed; a grace timeout never turns UNKNOWN into idle.
- **Crashed updater lease (SHOULD-FIX 4):** prove owner liveness using process identity, not PID age alone. A proven-dead lease owner becomes durable fault evidence so voice uses immediate unregistered admission. Unverifiable liveness is UNKNOWN. Never expire/reap a lock, silently reopen a generation, or mutate an app merely because a heartbeat is old. Test death in DRAINING and PREPARED.
- **Verified recovery and orphaned registrations (NIT 2):** if closeSync or lock removal fails after a registration rename, the caller may return an unregistered fallback while the published ledger record has no release closure. It remains blocking evidence. Recovery must reconcile those records, retained locks, diagnostic markers and uncertain PREPARED/COMMITTED bytes, prove the owning operation/process is no longer active, and only then retire owned evidence and restart/rejoin the participant. G2d never ages out or removes those records. Qualify recovery without stopping live dictation and preserve archived words throughout.

## Native admission and live participant adapter (G3)

`NativeUpdateGate` uses the same nonrecursive mkdir lock, strict state schema and
readable-directory ledger predicate, including enumeration before refusing a closed
gate. An unreadable closed ledger admits voice unregistered with a diagnostic.
Swift never writes, bootstraps or repairs gate state. A missing gate admits voice
unregistered without a marker while the daemon
initializes; the updater already refuses missing state. Malformed evidence, unsafe
ledgers, diagnostics and exhausted lock contention admit voice unregistered with
sticky fault evidence. Native synchronous admissions spin for at most 2 ms on a
healthy lock collision before diagnosing, matching TS. Only a valid closed gate
refuses playback. Drain ACK observations refuse UNKNOWN on contention without
diagnosing a healthy holder; no lock or another owner's registration is reaped.

History's `SettingsAudioPlayback` registers before AVAudioPlayer construction using
exclusive 0600 staging and rename, with no media sync on the audio boundary. Its
record spans queued clips, and releases after synchronous backend Stop, failed
start or final playback completion. Release contention retries its own record.
F5, Option+F5, replay, retranscription and previews already use G2 daemon admission;
the native level meter separately registers before opening input (including the
pre-daemon PTT transition) and retains that admission through wake restart until
confirmed meter stop/shutdown. Capture wiring and User Stop are unchanged.

Menu, Apple-event and SIGTERM quits refuse during capture, pending handoffs,
transcription, TTS or History playback, or a valid DRAINING/PREPARED/COMMITTED gate.
OPEN ignores orphan ledger records; missing, malformed, diagnostic or degraded
gates permit quit when no live work remains. Inactive disconnected/error modes
permit quit but never prove update-drain idle. Refusal uses the existing notice band.
Controlled quit additionally needs the exact COMMITTED lease and is final before
its ACK is returned; later ingress cannot cancel it. Termination is requested on
main after the socket queue attempts the ACK write, even if that write fails or
is skipped because the daemon peer disconnected. Singleton replacement
never escalates an incumbent's graceful refusal to force termination. SIGKILL and
OS force-quit cannot be prevented. A supervising SIGTERM timeout can escalate to
SIGKILL. Singleton replacement waits both daemon stop intervals plus a one-second
margin (3 seconds) before treating a surviving incumbent as a refusal. Startup
failures can leave before owning a server.

The authenticated daemon control endpoint adds `cmd:update_gate_drain|update_gate_quit`,
`lease`, and its existing private control `token`. It returns UNKNOWN or
`{kind:"ACKNOWLEDGED",native,daemon,identities}`. Both ACKs retain G2's exact
`{lease,activeOperations:0,openArchives:0}` format; identities separately contain
native/daemon `{pid,incarnation}`. Each call brackets a fresh native round trip
with G2's in-lock snapshot, never a cached ACK. Adopted/unowned daemons refuse.

Wire request `type:update_gate_drain` and reply `cmd:update_gate_drain_ack` carry
`action:drain|quit,id,pid,incarnation,lease,mac`. HMAC-SHA256 signs UTF-8
`kind|id|pid|incarnation|generation|operationId|ownerId|targetSha`; kind is the action
for a request and `ack-` plus the action for a reply. UUID case is preserved.
An app-incarnation secret is inherited by its owned daemon child and that child's
descendant processes; it is never persisted. OS peer PID plus owned-child identity
is the binding, so inheritance alone does not authorize another process.
Native validates the owned child and OS socket peer PID, one command owner, one
running VoiceBar bundle identity, pending work and ledger. Nonces, timeout and
disconnect fence replies. A quit may disconnect before the RPC reply: UNKNOWN
never proves exit. The updater must observe exact process exit itself.

Receipts are participant evidence, not installer authorization. Target verification,
off-socket competing-owner probes, mutation fencing, owner liveness and recovery
remain updater work. Swift/Bun tests prove isolated behavior; installed-app and
real-agent qualification remain with the lead. Tests inject private temporary gate
paths into system players and VoiceState; production does not detect test runners.
No drain writes Stop/Cancel signals.
