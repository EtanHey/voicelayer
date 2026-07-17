# Notch W1 Teleprompter Read-Back and HOLD-RECORDING Design

**Date:** 2026-07-17

**Status:** Approved

**Authority:** L1 `voicelayer.md` §10 clusters 1 and 4a, §8.11, §8.12

## Goal

Close two VoiceBar notch-app gaps without changing the frozen F5/dictation mechanism:

1. Keep the completed turn's original-script teleprompter visible, expanded, and scrollable for read-back until the user dismisses it or a new turn begins.
2. Add an explicit HOLD-RECORDING control that keeps a VAD recording open through a thinking pause while preserving manual stop, cancel, and the overall recording timeout.

## Constraints

- Display text remains the original script. Word-boundary text supplies timing only and must never replace display spelling.
- The existing F5, paste, hotkey, booking, capture, and transcription mechanisms remain unchanged except for the narrow silence-policy gate required by HOLD.
- TypeScript and Swift socket command definitions remain hand-mirrored.
- Visual and behavioral verification uses only an isolated release-built app and isolated socket/state paths. The resident `/Applications/VoiceBar.app` and running daemon are never stopped, replaced, or signaled.
- The OpenSpec change folder remains a throwaway analyzer test-drive. L1 §10 is the authority.

## Selected Architecture

### Retained teleprompter snapshot

`VoiceState` owns a distinct in-memory retained snapshot containing the completed playback's original display text and word boundaries. A playback-sourced idle event captures this snapshot before clearing live speaking state. Keeping retained content separate from `statusText` prevents idle labels, replay state, and future subtitle events from mutating the completed turn.

The VoiceMode remains `.idle` after playback. Read-back is a presentation condition layered over truthful idle state, not a fake continuation of `.speaking` and not a new protocol mode. `VoiceBarPanelLayout` receives an explicit teleprompter-presentation flag so idle read-back gets the same full-width, tall envelope as live speaking.

### Lifetime and restore contract

- The snapshot is created only when a non-empty speaking turn transitions to playback-sourced idle.
- It survives ordinary idle and a transient disconnect/reconnect for the lifetime of the app process.
- It is cleared by explicit read-back dismissal or when a new recording/speaking turn begins.
- It is not persisted across app relaunch; the source contract guarantees turn lifetime, not historical storage.
- The eye control temporarily conceals/reveals live or retained content without destroying it. This is the restore path.
- The read-back × control is the permanent dismissal action and returns the ordinary idle pill/collapse policy.
- Replay remains available from idle and does not destroy the retained snapshot before playback starts.

### Read-back interaction

The same mounted teleprompter surface spans live playback and retained read-back where SwiftUI identity permits. In live mode it follows the existing word timeline. In read-back mode it stops timeline animation, renders all original-script words at readable opacity, exposes a vertical scroll indicator, and accepts native scroll gestures. Entering read-back does not restart karaoke timing from word zero.

Retained content suppresses the idle-collapse scheduler. This promotes PR #346's opt-in development policy into a content-driven product rule: a read-back surface cannot collapse to the green dot while its lifetime contract is active.

### HOLD-RECORDING command and state

The additive socket command is:

```json
{"cmd":"set_recording_hold","engaged":true,"id":"…"}
```

The command is accepted only while recording and returns the standard ack. Its schema is represented in both `src/socket-protocol.ts` and `flow-bar/Sources/VoiceBar/SocketProtocol.swift`.

The daemon writes the engaged state to a user-owned, cross-process recording-hold flag under VoiceLayer's state directory. The active recording loop reads that state on every VAD chunk. Recording start and finish clear stale state, so a crash cannot make the next capture start held.

HOLD is shown only when the daemon reports `mode: "vad"`; PTT already ignores silence and must not present a redundant control. The inactive button uses `hand.raised`; engaged state uses a filled, visually selected treatment. Accessibility labels are “Hold recording” and “Release recording hold,” with a hint explaining that audio capture continues through silence.

### Silence-policy semantics

While HOLD is engaged:

- audio capture continues;
- post-speech silence cannot auto-close the recording;
- pre-speech timeout cannot auto-close the recording;
- explicit stop and cancel remain immediate;
- the existing one-hour overall timeout remains authoritative.

Holding resets accumulated pre-speech and post-speech silence counters. Releasing HOLD therefore starts a fresh full configured silence window (currently `thoughtful`, 2.5 seconds) instead of closing immediately on silence accumulated while held.

`VoiceState` updates the selected button optimistically for immediate feedback. A rejected/no-op ack rolls back the requested state. Recording exit, transcribing, cancel, disconnect, or a new recording resets local HOLD presentation.

## Alternatives Considered

### Keep `.speaking` after playback

Rejected because it would claim audio is still playing, retain a misleading stop action, and distort state-dependent routing and diagnostics.

### Add a local `.readback` VoiceMode

Rejected because it would ripple through every exhaustive mode switch, theme, router, layout, and transition even though the daemon remains truthfully idle. An explicit presentation flag is smaller and more accurate.

### Convert held recordings to PTT or restart capture

Rejected because switching/restarting capture risks audio loss and broadens the frozen recording mechanism. A live silence gate is additive and preserves one continuous capture.

### Increase the thoughtful threshold

Rejected because a larger fixed threshold cannot express user-controlled engage/release behavior and would slow every unheld turn.

## Failure Handling

- HOLD while idle/transcribing receives a no-op ack and the client rolls back selection.
- A command-delivery failure follows the existing synthetic reject-ack path.
- A stale hold flag is cleared before every new capture and at every normal capture exit.
- Empty or non-speaking playback idle events do not overwrite the retained snapshot.
- If read-back is temporarily hidden, playback completion retains it and the eye control restores it; only × destroys it.

## Test Strategy

TDD proceeds in independent RED→GREEN slices:

1. Swift state tests for snapshot capture, original-text retention, boundary retention, lifetime, reversible hide/show, permanent dismissal, new-turn clearing, reconnect restore, and collapse suppression.
2. Swift presentation/layout tests for a full read-back envelope, static readable teleprompter policy, VAD-only HOLD visibility, selected-state accessibility copy, and click routing.
3. TypeScript protocol tests for strict `set_recording_hold` parsing and mirrored ack command typing.
4. TypeScript recording-hold tests for secure flag lifecycle and silence-counter behavior before speech, after speech, through HOLD, and after release.
5. Socket-handler tests for recording-only acceptance and idle/transcribing no-op behavior.
6. Focused suites after every slice, then full `bun test`, full `swift test`, isolated release build, `scripts/voicelayer-verify.sh --corpus 10`, and isolated visual/behavioral receipts.

## OpenSpec Rider

The throwaway scaffold's teleprompter and HOLD requirement rows will be expanded to match the approved lifetime, restore, accessibility, and silence-policy semantics. No analyzer run will be attempted: no analyzer executable exists locally, and the lane explicitly forbids hunting for another runner.
