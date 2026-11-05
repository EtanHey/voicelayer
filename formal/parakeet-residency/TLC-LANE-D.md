# Lane D: delete a resident recognizer

Checked with the repository's `ResidentRecognizer.tla`, extending the existing
selection/download model with a delete projection. Selection still stops both
owners and loads the selected engine eagerly; the runtime idle default stays 600 s.

Command (run in this directory, substituting each configuration):

```sh
../tlc.sh -workers 1 -config FixedDelete.cfg ResidentRecognizer.tla
```

| Configuration | Result | Evidence |
| --- | --- | --- |
| `OldDeleteLoaded.cfg` | Expected FAIL, exit 12 | `IdleLoadedCanDelete` fails in the initial state: P is resident, voice work idle, both engines installed, but Delete is disabled |
| `FixedDelete.cfg` | PASS, exit 0 | 50 generated / 22 distinct states, depth 7 |
| `Fixed.cfg` | PASS, exit 0 | Existing selection/recovery model: 1002 generated / 404 distinct states |
| `FixedDownload.cfg` | PASS, exit 0 | Existing nonblocking-download model: 44 generated / 24 distinct states |

Logs are in `results-lane-d/`. The fixed delete projection checks that loaded
engines remain deletable while idle, no deleted model remains resident, delete
excludes recognition requests, and unconfirmed cleanup blocks requests. Capture
arriving during cleanup preserves the files. The old refusal is a usability
invariant failure, not a claim that the old implementation deleted live weights.

The model abstracts process-exit confirmation and filesystem link validation;
focused Bun tests cover the awaited provider stop, socket ACK ordering, capture
recheck, clear refusal reasons, external links, and the link recheck after unload.
No installed recognizer was loaded, unloaded, or deleted for this qualification.

## QA-04: already-ready selection and setup cancellation

The base selection model now treats a selection of the already-ready desired
engine as a no-op. `OldReadyReselect.cfg` reproduces the prior stop/reload path:
`ReadyDuplicateKeepsLoaded` fails after `StopP` (exit 12, 5 distinct states).
`FixedReadyReselect.cfg` now drives the real `BeginPicker(desired)` guard and
passes with 4 distinct states (capture/request interleavings). This projection models
only the duplicate-selection bug; it does not invent an automatic revert path.

`RuntimeSetup.tla` models an owned setup child ignoring SIGTERM. With
`OldSetupCancel.cfg`, `CancellationFinishes` fails (exit 13, 2 distinct states).
`FixedSetupCancel.cfg` passes (exit 0, 5 distinct states), with fair SIGKILL,
reaping, and cleanup steps. `CleanupAfterExit` is a well-formedness check restating the cleanup guard;
it is not evidence for escalation. `CancellationFinishes` is the liveness
property distinguishing the old and fixed implementations. No real model
provisioning is qualified here.

Use the same TLC command above with `-config OldReadyReselect.cfg` or
`FixedReadyReselect.cfg` and `ResidentRecognizer.tla`; for setup use
`-config OldSetupCancel.cfg` or `FixedSetupCancel.cfg` and `RuntimeSetup.tla`.

## Standing mutant gate (round 2 and follow-ups)

Run `bash formal/parakeet-residency/check.sh` from the repository root. It checks
all seven fixed configurations, then every named mutant in `mutants.json` with
its committed `mutants/*.cfg`. Each run prints its jar version and SHA-256 and
writes fresh logs/summary under `.build.noindex/tlc-lane-d/run-*/`; the committed
`results-round2/` logs and table below remain historical receipts. Copies of the models are mutated only in a private
`.build.noindex/tlc-lane-d/` temporary directory, which is removed after the run.
Every Java process has an external 30-second deadline and is killed/reaped on
failure. Logs redact temporary checkout paths; counts and counterexamples stay.

`check.sh` rejects a missing mutant, a passing mutant, a failure on another
property, or a parser/runtime/deadlock/timeout error. Each temporal config names
exactly its target property. Both `Fixed.cfg` and `FixedReadyReselect.cfg` check
`ReadySelectionIsNoop`, an action property over the actual `BeginPicker` relation.
The `deletedDuringCapture` history variable latches a deletion while capture is
active; `NoDeleteDuringCapture` checks that it never becomes true. Removing the
actual `DeleteFiles` capture guard now fails this exact invariant.

## FIXED-3: partial gate evidence after a transcript commit

`ArchiveGateEvidence.tla` models a saved row and repeated STT attempts with or
without surviving text and gate removals. The transcript commit clears previous
diagnostics. The new removal record runs after that commit, before the caller
publishes the completed transcription. Both non-empty and empty results can
carry removal evidence; a transcribed row cannot carry not-transcribed detail.
This abstracts archive metadata writes only, not decoding or acoustic decisions.

Code mapping: live finalization (`input.ts:3511`), Ask pair commit (`:4286`),
archived retry (`:4458`) and retained retry (`:4581`) record the current backend's
gate marker after the transcript writer clears the previous attempt's marker.
The existing recorder's transcribed-row guard keeps the diagnostic out of
`not_transcribed_reason` and `not_transcribed_detail`.

`FixedArchiveGate.cfg` passes with 70 states. `FinalTranscriptEvidence` checks
that a completed non-empty result has exactly its new attempt's removal marker;
`NoFailureDetailOnTranscript` forbids not-transcribed details on saved results.
All four new configs are required mutants, run by the same `check.sh`:

| Mutant | Meaning | Exact failure | Exit / states |
| --- | --- | --- | --- |
| PartialRemovalDropped | 9b375e26's non-empty-result guard omits recording | FinalTranscriptEvidence | 12 / 50 |
| GateRecordBeforeCommit | Record before the writer clears old diagnostics | FinalTranscriptEvidence | 12 / 44 |
| GateMarkerStale | Successful clean attempt does not clear old marker | FinalTranscriptEvidence | 12 / 54 |
| GateDetailOnTranscribed | Ignore the recorder's transcribed-row guard | NoFailureDetailOnTranscript | 12 / 50 |

The final mutant table below is generated by the checker; all expected failures
are counterexamples, not successful model checks. `CleanupAfterExit` remains a
well-formedness row only.

| Run | Target | Exit | Distinct states | Accepted |
| --- | --- | --- | --- | --- |
| Fixed | fixed | 0 | 404 | True |
| FixedAssetsGate | fixed | 0 | 3 | True |
| FixedDelete | fixed | 0 | 22 | True |
| FixedDownload | fixed | 0 | 24 | True |
| FixedReadyReselect | fixed | 0 | 4 | True |
| FixedSetupCancel | fixed | 0 | 5 | True |
| FixedArchiveGate | fixed | 0 | 70 | True |
| OneModel | OneModel | 12 | 192 | True |
| UnknownBlocks | UnknownBlocks | 12 | 14 | True |
| ProvisionedSelectable | ProvisionedSelectable | 12 | - | True |
| MissingAssetsBlocked | MissingAssetsBlocked | 12 | - | True |
| GateDoesNotLoad | GateDoesNotLoad | 12 | 3 | True |
| DownloadNeverBlocksAdmittedRequest | DownloadNeverBlocksAdmittedRequest | 12 | 6 | True |
| VerifiedDownloadAlwaysPublishable | VerifiedDownloadAlwaysPublishable | 12 | 19 | True |
| IdleLoadedCanDelete | IdleLoadedCanDelete | 12 | - | True |
| DeletedModelNotResident | DeletedModelNotResident | 12 | 13 | True |
| DeleteExcludesRequest | DeleteExcludesRequest | 12 | 8 | True |
| NoDeleteDuringCapture | NoDeleteDuringCapture | 12 | 15 | True |
| ReadyDuplicateKeepsLoaded | ReadyDuplicateKeepsLoaded | 12 | 5 | True |
| ReadySelectionIsNoop | ReadySelectionIsNoop | 13 | 38 | True |
| CleanupAfterExit | CleanupAfterExit | 12 | 4 | True |
| CancellationFinishes | CancellationFinishes | 13 | 2 | True |
| PartialRemovalDropped | FinalTranscriptEvidence | 12 | 50 | True |
| GateRecordBeforeCommit | FinalTranscriptEvidence | 12 | 44 | True |
| GateMarkerStale | FinalTranscriptEvidence | 12 | 54 | True |
| GateDetailOnTranscribed | NoFailureDetailOnTranscript | 12 | 50 | True |
