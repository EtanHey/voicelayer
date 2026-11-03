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
Recovery of a stuck COMMITTED gate remains a separate operation.

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

There is no automatic committed-state recovery. Initial OPEN needs a separately
qualified, quiescent bootstrap. Successful leased completion runs only in the
existing controller after it reaps the installer child. It parses the canonical
installed Info.plist outside G1, requires GitCommit == lease.targetSha, then
obtains a fresh authenticated G3 drain round trip from the NEW native/daemon pair.
A new receipt cache rejects the retired incarnations and unchanged PID/birth
identities, verifies the native executable is the canonical installed VoiceBar,
and verifies the daemon's parent. Old drain receipts cannot complete an update.
Before acquiring G1 it samples process identity; the callback rechecks the
receipt's one-second freshness, unchanged installed plist bytes, the exact
COMMITTED lease, empty readable admissions, clean diagnostics, and this process's
matching durable controller PID/identity. It durably publishes OPEN with the
lease generation and released lease, then removes only the matching controller.
The new app/daemon reread the gate on their next admission; no restart is needed.
The durable APPLIED result is the receipt: no post-COMPLETE identity sample or
gate readback may confuse a subsequent owner's REQUEST with failed completion.
No successor startup writer is added, avoiding two competing completion owners.
Verification failure retains COMMITTED and the controller, writes a recovery
receipt, prints the availability repair command below, and returns nonzero even
if the child exited 0. Uncertain persistence retains G1/fault evidence; never
assume a failed filesystem transaction left the previous bytes untouched.
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

The updater prints `RECOVERY_REQUIRED`, the gate and receipt paths, and a refusal
saying VoiceBar may be stopped. It gives this exact availability repair command,
to run only after the owning updater exits:

```bash
voicelayer setup --cask-postflight
```

That command restores the canonical bundle's UI/agents when no live controller
owns startup. It preserves the COMMITTED gate and evidence; it does **not** restore
voice admission or complete committed-gate recovery. Do not delete the gate to retry.

Proposal: the outer controller should restore the previous, verified bundle after
a pre-mutation quit refusal only once all original owners are positively absent,
no competitor exists, and its recorded bundle identity still matches. This follows
G0/G1's availability restoration while retaining closed admission. Do not relaunch
from this observer: its refusal can mean PID reuse, a competing app, or an unknown
owner, and it has no verified bundle custody. Post-mutation failures need the
installer's final canonical bundle instead. Automatic restore is a separate change;
this lane makes refusal and manual availability repair explicit.
