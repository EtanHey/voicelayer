# Update gate contract, version 1

Status: shared schema, transition semantics and locked persistence. Runtime admissions,
installation and recovery are not connected; this alone does not protect a live swap.

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
the released request cannot acquire that generation again. COMMITTED cannot reopen
in this slice. Verified completion and recovery belong to later adapters.

Adapters must read the authoritative state, obtain current participant evidence,
transition, and durably persist the result within the same cross-process critical
section used by admissions. The pure function does not serialize two snapshots.
Only a trusted owner may submit commands; adapters validate participant process
identities, current readiness and staged target verification. Persisted preparation
does not prove readiness after an app or daemon restart: reconcile participants
before commit. An absent owner or expired heartbeat never opens the gate.

## On-disk serialization and Swift contract

The default is `update-gate.json` under the private VoiceLayer state directory
(`VOICELAYER_STATE_DIR`, otherwise `~/.local/state/voicelayer`).
`VOICELAYER_UPDATE_GATE_PATH` overrides the complete path. Swift must resolve the
same override and root. The UTF-8 JSON object has version 1 and one of these forms:

| kind | Fields besides version/kind |
| --- | --- |
| OPEN | generation (safe integer >= 0), released (null initially, otherwise last cancelled lease) |
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

There is no automatic bootstrap or committed-state reopening. Initial OPEN needs
a separately qualified, quiescent bootstrap; successful install/recovery reopening
needs new app/daemon readiness for the same owner and generation in later adapters.
The preload forcibly redirects the gate and children into the run's `.test-tmp/`
tree. The resolver requires the redirect; storage rejects escapes and symlinks.

The focused storage suite races two independent Bun processes behind a barrier,
holds the winner's critical section to force overlap, and checks exactly one commit.
It also checks persisted fencing/replay, UNKNOWN, verification and failure retention.
Swift/Bun runtime interoperability and real installed-app safety remain G3/batch
proofs; no Swift build or live swap was performed for this shared primitive slice.
