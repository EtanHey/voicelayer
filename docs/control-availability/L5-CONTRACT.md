# L4 → L5 handoff

Contract slice only. Application conformance, native hover/AX, installed identity,
one-microphone operation and audio retention are NOT_RUN by this slice.

Consume `VoiceControlAvailability.evaluate(_:_: )`, `VoiceControl`,
`ControlAvailabilityFacts` and `ControlAvailability` in VoiceBarUI.
Map each actual surface's visibility, callback, data, connection, current owner,
pending ACK and operation-specific constraints into facts. Use `isVisible`,
`isEnabled`, `tooltip` and `accessibilityHint` on pointer, keyboard and AX paths.
Use native `PillControlTooltip` in the nonactivating panel. Re-evaluate at click;
the final owner must independently validate after its final await.

`ownerReason` adds the operation's existing constraints (assets, keep-one-model,
foreign ownership, playback generation, timing target, actual updater launcher).
Do not use it to silently implement the model's conservative proposals.
`explain` accepts a key/Delete/Quit explanation, not the requested media effect.
Emergency and paired release resolve existing take identity/lock semantics;
the pure result is not authority to cancel an unrelated take.

Family mapping: H03/F23/C01 → archiveDrawer/archiveWindow/archiveLatest;
G04/G17/G18 → restartListener/update/checkUpdates; G13/K05 →
readClipboard/readSelectionKey; G07-G10 → microphoneEdit (per AX target);
T01/T02/T14 → selectRecognizer; T03-T13 → corresponding management cases;
S01-S05 → clone cases; S13/S14/F22 → preview/historyPlay; N15/N17 →
previousRead/nextRead; N04/PTT pause → recordingHold/recordingPause.
K01/K03/K07/N01 → record, resolved separately from pairedRelease.
Dictionary included entries use dictionaryEdit readOnly; Commit requires ACK.
Modal/IME/editor priority is an owner obligation, not inferred from visibility.

`c5-inventory.json` is regenerated with `python3 docs/control-availability/c5-inventory.py`.
Stable cell IDs are FAMILY:PROJECTION; overlays have separate overlay:name IDs.
Only source-revalidated historical bad cells are REMOVED or SURVIVING. Other
historical known cells remain NOT_REPLAYED. Historical UNKNOWN stays UNKNOWN.
C5 true recording pause makes old Z=N obsolete; its cells are newly UNKNOWN.
This is source evidence, not a claim that a rendered control was clicked.
Physical-key and Quit cells need intent/owner-policy refinement: 19 historical
bad cells stay UNKNOWN_REFINEMENT, rather than counting an accepted explanation
as a failed media effect. The other historical bad cells are 24 removed and 34
surviving at the source layer; these counts never establish native acceptance.

L5 must independently assert rendered enablement, local acceptance and final-owner
acceptance for surviving cells, including sibling surfaces and pointer/AX/key.
Imported Old/Mut cases are design witnesses, never remaining C5 defect counts.
Proposals still needing lead resolution: clone Start/speech lock, transcription
playback restrictions, download provisioning lock, ConfirmDelete disable and Quit
disable. Keep Delete Explain working. No new invariant is designed in this lane.
