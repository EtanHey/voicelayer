# Private QA receipts (v1)

Run from the checkout whose HEAD is under test:

```sh
python3 scripts/qa-receipt.py run --lane L10 -- python3 scripts/test-qa-receipt.py
python3 scripts/qa-receipt.py validate /absolute/private/run/receipt.json
```

The first command prints one receipt path under
`~/.local/state/voicelayer/qa-receipts/<unique-run>/`. It returns the child exit
code (signals become exit 1), with combined output in a private, hash-sealed
`output.log` only when nonempty. No separate `.pid` or `.exit` files.
The directory is created exclusively with mode 0700; files use umask 077.
Never put credentials in command arguments. The command and environment are
not copied into receipt metadata. Output may contain private data and stays private.

The Python validator defines the strict v1 schema: schema version, unique run,
lane, source HEAD, pseudonymous host, supervisor PID, UTC timestamps, status,
exit code and evidence list. Evidence has only a basename, SHA-256 and private
visibility. Extra fields, inline output, missing identities, traversal, symlink
references, missing files, changed bytes and contradictory PASS/exit fail closed.
It checks integrity, not authenticity, semantic privacy or native acceptance.
Do not treat its success as permission to publish the receipt or referenced files.
A canary in an inline field is rejected; a canary inside private sealed output
is deliberately accepted without copying it into metadata.

RUNNING is never PASS. Abrupt supervisor death can leave RUNNING; an operator
must investigate and report UNKNOWN/INTERRUPTED, never infer success from a PID
or the absence of output. PID is observational metadata, not process custody or
authority to signal. This tool supplies no cancellation or timeout policy.
NOT_RUN, UNKNOWN and HOLD retain null exit codes. PASS requires exit 0; FAIL
requires nonzero exit. Use separate receipts for separate checks/proof layers.

Adoption: new QA invocations use this wrapper; existing orchestration adapters
must be routed by their owners before replacing their cue protocol. This lane
does not change existing release scripts, hooks, app lifecycle or archived runs.
Legacy artifacts remain evidence. No cleanup or archive/restore is performed.

Publication boundary: keep full QA sessions, recordings, transcripts, raw logs,
local paths and archive ledgers private. Public PRs receive a manually reviewed
synthetic repro and redacted before/after evidence, with source/build identities,
status and explicit untested surfaces. Hashes alone do not make content public-safe.
Existing tracked files are unaffected by ignore rules; audit them before removal
or publication. Do not mass-delete screenshots or remove `site/`.
