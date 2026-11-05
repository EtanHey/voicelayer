# Update gate contract, version 1

Status: shared schema, admission-aware locked persistence, and verified controller
completion. Installed real-binary acceptance is a separate release qualification;
source and isolated tests alone do not protect or qualify a live swap.

`src/update-gate.ts` exports the Zod state, command, acknowledgement and lease schemas,
their inferred types, `readUpdateGate` and `transitionUpdateGate`.
Wire keys and enum values are case-sensitive. Extra fields and incompatible versions
are rejected. Missing, malformed or unreadable state must be passed as unknown input;
it yields `UNKNOWN`, which refuses all transitions. There is no idle fallback or
automatic initialization. A future verified bootstrap supplies the initial OPEN
record with generation 0 and released null.

Every lease binds a positive safe-integer generation, UUID operation ID, UUID owner
incarnation and lowercase full target merge SHA. The owner ID is retained across a
job reconnect, but a new owner incarnation cannot assume the previous owner's lease.
An ID is a fencing identity, not authentication, proof of process liveness or a PID.

OPEN alone permits admission. DRAINING, PREPARED and COMMITTED all close admission.
REQUEST advances exactly one generation from OPEN. An identical duplicate request
returns UNCHANGED even after preparation or commit. PREPARE needs native and daemon
acknowledgements for that exact lease, with zero active operations and archive writes.
COMMIT applies once from PREPARED; a duplicate returns UNCHANGED. Callers perform
mutation only after durably persisting an APPLIED commit, never for UNCHANGED.
CANCEL reopens only the matching precommit generation. Its duplicate is idempotent;
the released request cannot acquire that generation again. COMPLETE reopens only COMMITTED for that exact lease, with installerExitCode 0,
installedSha equal to lease.targetSha and participantsVerified true. Its matching
duplicate is idempotent. These fields are not client authorization: the trusted
controller must also supply fresh evidence inside the admission-aware G1 write.
A verified successor may supply the recovery proof described below.

Adapters must read the authoritative state, obtain current participant evidence,
transition, and durably persist the result within the same cross-process critical
section used by admissions. The pure function does not serialize two snapshots.
Only a trusted owner may submit commands; adapters validate participant process
identities, current readiness and staged target verification. Persisted preparation
does not prove readiness after an app or daemon restart: reconcile participants
before commit. An absent owner or expired heartbeat alone never opens the gate.

## On-disk serialization and Swift contract

The default is `update-gate.json` under the private VoiceLayer state directory
(`VOICELAYER_STATE_DIR`, otherwise `~/.local/state/voicelayer`).
`VOICELAYER_UPDATE_GATE_PATH` overrides the complete path. Swift must resolve the
same override and root. The UTF-8 JSON object has version 1 and one of these forms:

| kind | Fields besides version/kind |
| --- | --- |
| OPEN | generation (safe integer >= 0), released (null initially, otherwise last cancelled or completed lease) |
| DRAINING | lease |
| PREPARED / COMMITTED | lease, native acknowledgement, daemon acknowledgement |

A lease is `{generation, operationId, ownerId, targetSha}`. An acknowledgement is
`{lease, activeOperations: 0, openArchives: 0}`. UUIDs and lowercase 40-character
merge SHAs are required. Unknown fields, mismatched leases, nonzero counts and
incompatible versions are UNKNOWN. Process identity/liveness is deliberately not
implied by these acknowledgement fields: G2/G3 must validate live incarnations,
pending handoffs, archive durability, absence of unregistered owners and the target.

`src/update-gate-storage.ts` provides `applyUpdateGateCommand`, which acquires the
lock, reads and validates current state, transitions, persists APPLIED, then unlocks.
APPLIED COMMIT additionally requires a synchronous `verifyCommit(state)` returning
exactly true **inside that lock**; missing/negative evidence refuses UNKNOWN.
Persisted PREPARED alone never authorizes commit after restart. Duplicate COMMIT
returns UNCHANGED and cannot authorize repeating an installer mutation.
`readUpdateGateFile` is observational only (UNKNOWN while locked). An OPEN read is
not an admission token: G2/G3 must serialize registration and closure under
`withUpdateGateLock`, with full work lifetime accounting supplied by those adapters.

Acquisition is one nonrecursive `mkdir(gatePath + ".lock", 0700)`; EEXIST means
locked. Bun's `mkdirSync` and Swift's `Darwin.mkdir` contend for the same directory
entry in the local filesystem. There is no separate existence check or recursive
directory adoption. Only one creator succeeds, independently of language; all
others receive EEXIST. See Apple's [mkdir(2)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/mkdir.2.html).
Swift must use this syscall directly, not `createDirectory(withIntermediateDirectories: true)`.
The successful caller alone removes its empty lock with `rmdir`, after success.
Lock files, symlinks, permissions/I/O errors and orphaned directories refuse work.
Never unlink/reap/replace a lock on age, heartbeat, PID death or normal shutdown.
Recovery must first prove all former holders/installers quiescent; it is a later slice.

Critical sections are synchronous and short, with no await/audio/network waits.
Any callback exception, returned promise or persistence error retains the lock.
Writers exclusively create `.lock/state.json` (0600), write/fsync it, rename it
over the gate on the same filesystem, fsync the parent directory, and on Darwin
require `fcntl(fileFD, F_FULLFSYNC, 0)` before closing/unlocking. Swift must use the
same sequence. No best-effort durability fallback is allowed. Apple's
[rename(2)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/rename.2.html)
defines the replacement semantics. A failed transaction may have reached disk:
the retained lock makes its outcome UNKNOWN until verified recovery.

A successful controller reaps its installer child, checks installed GitCommit against
lease.targetSha, and authenticates a fresh successor native/daemon drain. Readiness
and acquisition retry for up to 60 seconds with 100 ms exponential backoff capped
at one second. Each G1 acquisition stays within the one-second participant receipt
(minus 50 ms reserve); acquisition timeout obtains a new round trip before retrying.
Positively unsafe identity evidence, gate faults and refused COMPLETE do not retry.
The locked callback checks exact lease/custody, unchanged installed bytes, fresh
participant proof, empty admissions and clean diagnostics. Durable OPEN releases
that generation and removes only its matching controller receipt.

R6 adds a successor startup backstop after the daemon socket is serving. VoiceBar
passes its own stamped GitCommit to its child. Recovery requires that SHA and the
canonical installed GitCommit both match the COMMITTED target. The matching
controller must be verifiably absent for five seconds; a live controller resets
the grace period and the observation ends after 60 seconds. Unknown process
identity and PID reuse retain custody. Fresh authenticated successor evidence and
the same G1 COMPLETE guards remain mandatory. This availability-only proof uses
the verified running target in place of the dead controller's child-exit receipt;
it never authorizes another installer mutation. Repeated startup sees OPEN and
has nothing to recover. Orphaned G1, diagnostics, active admissions, foreign or
missing custody, and mismatched prior bundles stay retained for qualified recovery.
R5 (missing gate with retained admissions) is outside this backstop.

User Quit (menu, canonical external Quit, SIGTERM) never depends on gate evidence
and preserves it. Only dictation capture/save work may delay Quit: show the saving
notice, issue the existing Stop, and wait up to six seconds before shutdown.
A legacy/MCP Stop retains a Quit-only save wait through its optimistic UI change.
Archive settlement, idle/cancel, errors, connection changes and a new capture retire
that wait. The incremental recovery WAV is preserved if no History row published;
use Retranscribe Last in that case. Authenticated controlled-update Quit retains
its separate lease checks.

The preload forcibly redirects the gate and children into the run's `.test-tmp/`
tree. The resolver requires the redirect; storage rejects escapes and symlinks.

The focused storage suite races two independent Bun processes behind a barrier,
holds the winner's critical section to force overlap, and checks exactly one commit.
It also checks persisted fencing/replay, UNKNOWN, verification and failure retention.
Swift/Bun runtime interoperability and real installed-app safety remain G3/batch
proofs; no Swift build or live swap was performed for this shared primitive slice.

## Controlled-quit exit observation (G3)

After the one authorized quit, unavailable identity evidence is still exiting,
never proof of exit: empty `ps` while `kill(pid, 0)` succeeds, teardown, unreaped
and same-birth `<defunct>`/`(basename)` observations keep polling for five seconds.
Both process samples must prove absence, bracketing the exact COMMITTED lease,
empty admission ledger and clean diagnostics checked under G1 on **every poll**.
A positively different birth/executable or competing VoiceBar refuses immediately;
unknown process-table evidence waits until the deadline and cannot authorize a swap.
Only confirmed absence can finish the final poll just past the deadline; uncertainty
at that point refuses. No process is killed.

The updater retains a recovery receipt on failure. An installer child that ran
its outer script restores the observed bundle on exit. A matching successor verifies abandoned
COMMITTED completion; otherwise custody stays closed. Never delete a gate or reap
G1 to retry. Source/model checks do not qualify an installed swap.
