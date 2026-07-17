# Spec delta: voicebar-notch (throwaway analyzer test-drive)

> **THROWAWAY.** Authority lives in `orchestrator/standards/layers/voicelayer.md` §10. This delta restates it in openspec requirement form and records the W1 requirement detail.

## ADDED Requirements

### Requirement: Teleprompter persistence after turn-end

After playback ends, VoiceBar SHALL retain the completed teleprompter as an in-memory, scrollable read-back while the operational mode remains truthfully idle. The transition SHALL preserve the current eye-control visibility state: visible playback remains visible for read-back, while temporarily hidden playback remains hidden but restorable. The read-back SHALL preserve the original display script and matching word boundaries, SHALL NOT restart the playback timeline, and SHALL render all words at a uniform readable opacity with native vertical scrolling.

The retained content SHALL survive the idle-collapse timer and transient/generic idle events for the current app session. Eye hide/show SHALL be reversible and SHALL NOT destroy retained content. The × control SHALL permanently dismiss the retained snapshot. A new recording or speaking turn SHALL clear the previous snapshot. App relaunch persistence is not required.

#### Scenario: Read-back after a completed answer

- **WHEN** TTS playback ends with a non-empty original display script
- **THEN** VoiceBar enters idle while the full original-script teleprompter remains available and scrollable, preserving its prior eye-control visibility state
- **AND** phonetic respells or engine-channel pronunciation text never replace the displayed spelling
- **AND** the timeline no longer advances or auto-scrolls
- **AND** the idle-collapse timer does not collapse the retained read-back

#### Scenario: Hide, restore, and permanently dismiss

- **WHEN** the user activates the eye control on retained read-back
- **THEN** the teleprompter is hidden without destroying the snapshot
- **AND WHEN** the user activates the eye control again
- **THEN** the same retained content is restored
- **AND WHEN** the user activates ×
- **THEN** the retained content is destroyed and normal idle collapse may resume

#### Scenario: New turn replaces retained content

- **WHEN** a new recording or speaking turn begins
- **THEN** the previous read-back snapshot is cleared before the new turn is presented

### Requirement: Hold-recording control

The recording surface SHALL offer a VAD-only HOLD-RECORDING control. The control SHALL use `hand.raised` when released and `hand.raised.fill` when selected, with accessibility labels “Hold recording” and “Release recording hold.” Push-to-talk SHALL NOT expose this control because PTT already ignores silence auto-close.

While HOLD is engaged, both the pre-speech no-voice timeout and post-speech silence timeout SHALL be suppressed and their accumulated silence counters SHALL reset. Releasing HOLD SHALL start the applicable silence countdown from a fresh full window. Explicit stop, explicit cancel, and the overall recording safety timeout SHALL remain effective while held.

#### Scenario: Post-speech thinking pause does not end the turn

- **WHEN** VAD recording has detected speech and the user engages HOLD-RECORDING
- **AND** silence lasts longer than the active silence-mode threshold
- **THEN** recording continues
- **AND WHEN** the user releases HOLD
- **THEN** a fresh full post-speech silence countdown begins

#### Scenario: Pre-speech thinking pause does not time out

- **WHEN** the user engages HOLD-RECORDING before speech is detected
- **AND** silence lasts longer than the normal pre-speech timeout
- **THEN** recording continues
- **AND WHEN** the user releases HOLD without speaking
- **THEN** a fresh full pre-speech countdown begins

#### Scenario: Explicit termination remains authoritative

- **WHEN** HOLD-RECORDING is engaged
- **AND** the user sends explicit stop or cancel, or the overall safety timeout expires
- **THEN** recording ends according to that explicit termination path

### Requirement: Waveform truth

All waveform renderings (agent playback, user recording, listening state) SHALL be driven by live audio amplitude, with a single render variant.

#### Scenario: Agent playback waveform moves

- **WHEN** agent TTS audio is audibly playing
- **THEN** the agent-side waveform amplitude varies with the playback signal (not static, not on/off pinned)

### Requirement: Latency signaling

The interface SHALL display a generating/thinking state whenever the ask→response gap exceeds a signaling threshold, and the TTFA breakdown (queue/synth/transfer) SHALL be instrumented.

#### Scenario: No unsignaled dead-air

- **WHEN** more than 2 seconds elapse between turn close and the next TTS onset
- **THEN** the widget shows a visible generating/thinking state instead of disappearing

### Requirement: Two-channel display in the live teleprompter

Display text SHALL always show the original script; pronunciation respells/SSML/phonetic hints SHALL travel in the engine channel only.

#### Scenario: Respelled name never renders

- **WHEN** the pronunciation dictionary respells a token for the TTS engine (e.g. a name)
- **THEN** the teleprompter displays the original spelling, never the respell
