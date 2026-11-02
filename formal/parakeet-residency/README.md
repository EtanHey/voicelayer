# Recognizer residency admission model
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
java -XX:+UseParallelGC -cp ~/.cache/tla/tla2tools.jar tlc2.TLC -config OldDownloadBlocks.cfg ResidentRecognizer.tla
java -XX:+UseParallelGC -cp ~/.cache/tla/tla2tools.jar tlc2.TLC -config FixedDownload.cfg ResidentRecognizer.tla
```

This projection checks admission enabledness and publication availability, not
scheduler fairness, filesystem durability, native inference, or installed-app
behavior. The Bun regression uses synthetic pinned bytes and paused transfer or
runtime setup; it exercises the actual shared request admission and downloader.
