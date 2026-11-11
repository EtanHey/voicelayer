# L4 → L5 handoff: control availability

Contract only: nothing in the app calls these types yet. App conformance, native hover/AX,
installed identity, one-microphone operation and audio retention are NOT_RUN here.

## What L5 calls

```swift
let facts = ControlAvailabilityAdapter.facts(reading)          // once per render, from VoiceState
// On a surface owning the History player, use its source-backed snapshot bridge:
let historyFacts = ControlAvailabilityAdapter.facts(reading, historyPlayback: historyPlayback)
let a = VoiceControlAvailability.evaluate(control, facts, handlerInstalled: onAction != nil)
// a.isVisible, a.isEnabled, a.tooltip (PillControlTooltip in the notch), a.accessibilityHint
```

- `ControlFacts` is the formal model's state, typed: connection, gate, capture phase
  (`none / reservedOpening / capturing(ptt|vad) / paused / draining(successorQueued:) / askCapturing`),
  processing (`transcription / historyRetranscription / askAnswer`), playback
  (`none / preparing / playing / paused / readback / askSpeaking`), presentation (hidden, drawer, modal),
  `historyVoiceBusy` (external History-player admission, independent of playback),
  `voiceError`, `physicalGesture`, `settingsService`, and one pending per operation. Every field is a
  required init argument; there is no default gate.
- Surfaces never build `ControlFacts` by hand and never test `mode` themselves. Per-item data rides on the
  control: `.retranscribe(surface, audio:)`, `.historyPlay(audio:)`, `.previousRead(available:)`,
  `.nextRead(queued:)`, `.microphone(edit, eligible:)`, `.recognizer(action, row)`, `.clone(action, engine)`,
  `.processingToggle(key, lockedBy:)`, `.dictionaryEdit(readOnly:)`.
- `handlerInstalled: false` returns `.unwired` (`isContractFault`). L5 tests must assert no rendered control
  is ever `.unwired`; it is a wiring bug, never a working-looking button.
- `.explain` (selection key only) is an accepted intent: show/announce the reason, start no media.
- Handlers re-evaluate at click and the final owner re-checks identity/admission after its last await.

## Adapter input (`VoiceStateReading`): where each value comes from

| Field | Source |
|---|---|
| `mode`, `isConnected`, `recordingMode`, `isRecordingPaused`, `isAskCapture`, `processingTakeCount`, `isHistoryRetranscriptionPending`, `supportsRecordingJobs`, `isPlaybackPreparing`, `isPlaybackPaused`, `isTeleprompterReadback`, `isHidden` | `VoiceState` public properties of the same name |
| `hasQueuedRecording` | `VoiceState.queuedRecordingTakeID != nil` |
| `captureAdmission` | `VoiceState.captureAdmissionPhase` (lane L4b, stacked on this branch). Opening = reserved before live PCM, even while `mode` reads idle |
| `agentAskSession` | **No VoiceState read exists yet.** The owner lane must expose "Ask prompt speaking" / "Ask answer transcribing" before L5 wires media buttons, the selection key or Record; passing `.none` drops the Ask refusals |
| `gate` | `ControlVoiceGate(permitsNewVoice: NativeUpdateGate.shared.permitsNewVoice())` |
| `isHistoryPlaybackActive` | `historyPlayback.playingURL != nil`: the player's OWN active clip. Use the adapter overload above to read this directly from the real player |
| `isHistoryVoiceBusy` | `historyPlayback.isVoiceBusy`: external voice owners or `!canPlay()`. Kept separately as `ControlFacts.historyVoiceBusy` for History Play admission; never converted into a playback phase |
| `drawer`, `isModalPresented` | the notch surface (drawer state) and the presenting window (sheet/alert) |
| `hotkeyPhase` | `VoiceState.hotkeyPhase` |
| `modelsSettings` | `ModelsSettingsState`: `.unavailable(effortDisabledReason)` when not available, `.busy(busyReason)` when busy, else `.ready` |
| `pending` | one entry per in-flight acknowledgement: hold/pause (VoiceState's private `pendingRecordingHold`/`pendingRecordingPause`: owner lane exposes them), `update`/`updateCheck` (`VoiceBarUpdates.phase`), `clone` (clone controller in flight), `recognizerMutation` (picker transition), `processing(key)` (`processingPending[key]`), `speech(key)`/`speechPreview` (`speechPending`), `dictionaryCommit`, `shortcutCheck` |

## Controls per surface

| Surface | Controls |
|---|---|
| Notch wings / teleprompter (BarView) | `record` (start mic), `stopRecording`, `cancel`, `recordingHold`, `recordingPause`, `stopSpeaking` (beside Stop recording: separate intent, `scope:"speech"`), `pausePlayback`, `resumePlayback`, `previousRead`, `nextRead`, `replay`, `seek`, `speedChip`, `dismissTeleprompter`, `showTeleprompter`, `dismissError`, `chooseMicrophone` |
| Notch drawer (NotchSurface, NotchSettingsDrawer, NotchHistoryPanel) | `openHistory`, `openSettings`, `closeDrawer`, `drawerTab(tab)`, `retranscribe(.drawer, audio:)`, `historyCopy`, `historyPaste`, `checkUpdates`, `update` |
| Settings window: sidebar | `windowTab(tab)` |
| Settings › General | `readClipboard`, `restartListener`, `checkShortcut`, `permissionFix`, `hide`, `show`, `microphone(edit, eligible:)` for Make default / drag reorder / move / visible-first |
| Settings › Transcription | `recognizer(.select/.loadAndSelect/.load/.unload/.download/.cancelDownload/.requestDelete/.confirmDelete, row)`, `processingToggle(key, lockedBy:)` |
| Settings › Speech | `speechSetting(key)`, `preview(profile)`, `clone(action, engine)` |
| Settings › Dictionary | `dictionaryEdit(readOnly:)`, `dictionaryCommit` |
| Settings › History rows | `historyPlay(audio:)`, `historyCopy`, `historyPaste`, `historyReveal`, `retranscribe(.window, audio:)`, `historyNavigate` |
| Right-click menu / popover | `windowTab(.general)` (Settings…), `hide`, `copyLastTranscript`, `pasteLastTranscript`, `retranscribe(.latest, audio:)`, `chooseMicrophone` (Change…), `quit` |
| Hotkey / router | `record`, `stopRecording`, `pairedRelease`, `cancel`, `readSelectionKey` (always delivered; reads or explains) |

Recognizer rows: the selected row's Load is `.load`; a non-selected row's Load is `.loadAndSelect`
(`VoiceState.manageRecognizer` turns it into a select), shown where Load shows, with Select's rules.

## Rules worth knowing

- Stop recording / Cancel / F5 release: enabled whenever a take is unfinished (any capture phase, queued
  successor, transcription or History job), through closed gate, modal, hidden, pending and disconnection;
  otherwise disabled with "No unfinished take". Stop speaking follows live speech only ("Nothing is speaking").
- Local navigation (tabs, drawer open/close, Choose microphone, Show, Dismiss/Show teleprompter, Dismiss
  error, version check, History copy/navigate/reveal, Copy last transcript, permission fix) is enabled
  whenever visible. Nothing can disable it.
- During an agent Ask (speaking, capturing or answering): Read Clipboard, Preview, History Play are refused
  and the selection key explains, all with "Answering a question". Preview and History Play are refused
  during playback ("Finish the current playback first").
- History Play additionally preserves external player admission with the existing
  `SettingsHistoryCopy.playBusy` explanation. That fact alone does not enable Stop speaking or mark
  speech active. The History player has no preparing/paused state; those flags come from VoiceState.
- Seek while paused is refused with "Paused. Press Play to seek", matching today's `VoiceState.seek`.
  Whether a paused click should seek remains an open product decision; this contract changes no owner behavior.
- A pending acknowledgement only affects its own control: a pending Lock never disables Record.
- Cancel Download works disconnected. Processing toggles show "Set by <VAR>" when env-locked.

## Deliberate differences from the model (CONFORMANCE proposals, lead-owned)

Each is applied exactly in `ModelExpectation.relax` and nowhere else: transcription-only block on
Resume/Previous/Next/Replay/Seek (any capture phase, draining included, still blocks); closed-gate Update;
closed-gate Quit; unfinished-take lock on Download and ConfirmDelete; clone Start capture lock; clone speech
lock. Emergency controls stay visible (disabled with the model's reason) where the model hides them.

### Playback refinement gate — excluded from the ready-to-consume handoff

`pausePlayback`, `resumePlayback`, `previousRead`, `nextRead`, `replay`, `seek` and `speedChip` are
**NOT READY for replacement of their existing UI/handler predicates**. Their phase-level cells include
the paused-Seek refusal, but do not yet express every source target constraint: e.g.
`VoiceState.isTeleprompterScrubSeekable` requires a positive playback duration, or a retained readback ID
and positive retained duration; word seeks also require matching utterance identity and timing.
L5 must retain these controls' existing owner/presentation predicates and explanations until an owner-backed
target/identity refinement is supplied. History's own player controls likewise keep their URL-specific
target checks. This exclusion does not defer the Preview/History Play media refusal fixes above.

## Proof in this PR

- `docs/control-availability/model/ControlAvailability.tla`: model 4bf20052 plus the source refinement
  refusing paused Seek in both UIReason and LocalGuard. `model-table.json` records the base blob,
  refined blob and refinement; no longer described as a verbatim copy.
- `model-table.py` runs TLC over the model's own `Seeds` and pins the table hash in `model-table.json`.
- `ControlAvailabilityModelOracle.swift` transliterates the TLA; `testOracleReproducesTLCTableExactly`
  proves it equals TLC's table. `testContractMatchesModelInEveryCell` checks the contract against it in
  every (control × phase) cell, including EnabledMeansAccepted against the model's independent guards.
- `ControlAvailabilityContractTests` asserts DisabledHasReason, StopAlwaysReachable, HideNeverCancelsATake,
  LocalNavigationAvailable, per-operation pending and the adapter mapping directly.
- History's external admission is an additional source refinement outside the abstract model axes;
  real `SettingsAudioPlayback` instances with injected silent backends exercise both independent facts
  through the adapter. These are source/model tests, not installed audio or native UI proof.

## C5 inventory

`c5-inventory.json` is regenerated with `python3 docs/control-availability/c5-inventory.py`. A historical bad
cell is SURVIVING only while its family's defect line is still present at C5 (`defectAnchor`); fixing that
line makes the generator fail and forces a relabel. Overlays without a source check are SOURCE_UNCHECKED.
Both Python ledgers run in the Bun suite (`src/__tests__/control-availability-ledgers.test.ts`).
