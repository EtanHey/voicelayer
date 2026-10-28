# Update gate contract, version 1

Status: schema, transition semantics and daemon bootstrap persistence. Runtime
admissions, installation and recovery are not connected in this slice.

`src/update-gate.ts` exports the Zod state, command, acknowledgement and lease schemas,
their inferred types, `readUpdateGate` and `transitionUpdateGate`.
Wire keys and enum values are case-sensitive. Extra fields and incompatible versions
are rejected. Missing, malformed or unreadable state must be passed as unknown input;
it yields `UNKNOWN`, which refuses all transitions. There is no implicit idle
fallback. `bootstrapUpdateGate` creates a private SQLite gate with generation 0
and released null, binding it to the current daemon's UUID, PID and kernel start
time in the same FULL-synchronous immediate transaction. After closing SQLite,
it fsyncs the file, atomically renames it into place and fsyncs the parent directory.
A nonblocking kernel flock on that directory serializes bootstrap publication and
restart claims; process death releases the lock. SQLite ownership transactions
also refuse contention immediately rather than waiting.

An existing readable, writable regular zero-byte file without recovery sidecars is the sole
legacy incomplete-create case bootstrap replaces. Nonempty partial headers and
all other corrupt content remain UNKNOWN. Private temporary files left by a crash
are never read as authoritative state.

Persisted OPEN alone is insufficient. Admission adapters must call
`readTrustedUpdateGate(db)` inside their admission transaction; this checks the
current owner's exact kernel start identity. Daemon-owned callers can also pass
their expected daemon UUID to reject an obsolete incarnation. Dead or unverifiable
owners yield UNKNOWN. Bootstrap can rebind an existing OPEN only when its previous
owner is proven dead and there are no unresolved admissions. The update lease's
numeric generation is preserved across daemon restarts.

DRAINING, PREPARED and COMMITTED are never reopened at startup. Corruption, missing
ownership and unavailable identity probes also refuse gate ownership. Diagnostics identify
the gate path and require reconciliation of the pending update and archives while
preserving state. This slice supplies no closed-state recovery or state-deletion tool.

In this standalone slice bootstrap is deferred until the daemon has started
listening and installed its lifecycle handlers. Gate refusal is logged and never
aborts daemon startup or changes current voice admission. Slice 2 must explicitly
coordinate bootstrap readiness with its trusted-state admission checks and startup
archive recovery; until then, successful daemon startup does not imply a trusted gate.

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

Tests exercise ordered contenders, fencing, duplicate commands, malformed evidence
and serialization round trips. They do not qualify Swift/Bun locking or installed
runtime safety. Those remain release blockers until the later slices are verified.
