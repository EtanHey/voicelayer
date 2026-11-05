# Recognizer residency admission model

## TLC tool pin and repeatable checks

Current runs resolve the checksum-pinned jar through `formal/tlc_support.py`,
then verify a frozen per-run copy before starting Java. No unversioned cache is required.

The historical M4 reference jar at `~/.cache/tla/tla2tools.jar` was:

- TLC **2.19 of 08 August 2024** (the committed receipt banner reports revision `5a47802`).
- SHA-256: `936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88`.

Recorded from the M4 Max cache on 2026-11-02. These bytes identify the historical
receipts below; current runs use `formal/tlc.lock.json` and print their actual identity.

Run `bash formal/parakeet-residency/check.sh` from the repository root. The
runner first tests its output validator, then checks every fixed configuration
and required mutant. TLC 2.19's unnamed temporal-failure summary and newer
nightlies' named temporal failures are accepted; a named failure must match the
expected property, and temporal configs must name exactly that one property.

Each run prints its actual TLC version, SHA-256, source path and output folder.
It freezes the jar bytes used by every child in a unique
`.build.noindex/tlc-lane-d/run-*/` directory, alongside `jar.json`, logs and
`SUMMARY.md`. The recorded identity distinguishes current runs from the
historical reference pin. Model scratch state
is removed after checking. Committed `results-round2/` files remain unchanged
as the historical receipt; rerunning the checker never rewrites them.

## Residency abstraction

The finite TLA+ abstraction checks one-model admission through picker cleanup/startup, symmetric previous-engine restoration, and legacy W load. Fixed:416 distinct states,1014 generated,depth24,OneModel/UnknownBlocks hold. OldLegacyRace and OldRecoveryRace each produce OneModel counterexamples (raw TLC logs/traces in the lab report).

Source joins: LegacyStart -> beginRecognizerMaintenance/withRecognizerMaintenance; BeginPicker -> beginRecognizerTransition; StopP/StopW -> selectRecognizer positive cleanup and busy rechecks; RecoverPrevious/RequestStart -> recognizerRecovery plus getBackend actual restored-provider reuse; UnknownCleanup/ConfirmedCleanup -> dedicated cleanup barrier/positive confirmation.

This is an order-of-events abstraction, not extracted source equivalence or a proof of all runtime behavior. In-flight provider error cleanup, native process/EOF facts, timing, decode quality and capture device behavior are outside it. Actual daemon and focused source evidence remain separate. No liveness assertion is made.

Run TLC with Fixed.cfg; negative configurations preserve two historical race witnesses. The macOS java launcher had no registered JRE; existing /opt/homebrew/opt/openjdk/bin/java performed the runs. No Java install was made.

## #656: asset presence and the circular picker gate

`assetsPresent` is cheap local metadata, separate from `models` (loaded engines)
and `attempted` (a previous runtime attempt). Init includes both installed and
missing Parakeet states. Existing residency actions leave these gate inputs
unchanged; the gate-only projection does not claim to model downloads or native
processes. `GateSelect` represents accepting a picker selection without loading.

`OldCircularGate.cfg` enables the old never-tried gate: a provisioned, sleeping P
with no previous attempt cannot be selected. TLC produces an initial-state
`ProvisionedSelectable` counterexample. `FixedAssetsGate.cfg` gates on assets:
provisioned P can be selected, missing P stays blocked, and status/selection does
not implicitly load any model. The fixed residency safety checks still pass.
See TLC-656.md for output extracted from the actual runs. This is enabledness
and safety evidence, not a model of every provisioning interleaving or native
runtime qualification.

## Download admission and publication (2026-11-02)

`DownloadSpec` is a separate projection using `pendingLegacy` for one engine's
in-flight download and `capture` for an admitted request. `BrokenLegacy=TRUE`
models the old download holding the maintenance owner across transfer, hashing,
and runtime setup. `DownloadNeverBlocksAdmittedRequest` checks that such a
request can enter immediately. `VerifiedDownloadAlwaysPublishable` checks that
final publication remains enabled even while a request is active or admitted.
Publication changes files atomically and never loads a model. Busy state is not
an admission gate for downloading or publication; same-engine load/delete and a
second same-engine download are excluded by per-engine ownership in source.

Actual TLC receipts are in `results-download/`: `OldDownloadBlocks.log` exits 12
with the invariant counterexample after DownloadBegin -> DownloadAdmit;
`FixedDownload.log` exits 0 (44 generated, 24 distinct, depth 7), checking both
new invariants. `Fixed.log` exits 0 for the existing residency model (1014
generated, 416 distinct, depth 24). Run each from this directory with:

```sh
../tlc.sh -config OldDownloadBlocks.cfg ResidentRecognizer.tla
../tlc.sh -config FixedDownload.cfg ResidentRecognizer.tla
```

This projection checks admission enabledness and publication availability, not
scheduler fairness, filesystem durability, native inference, or installed-app
behavior. The Bun regression uses synthetic pinned bytes and paused transfer or
runtime setup; it exercises the actual shared request admission and downloader.
