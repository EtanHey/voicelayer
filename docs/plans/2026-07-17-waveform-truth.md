# VoiceBar Waveform Truth Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Drive every VoiceBar audio waveform from real recording or playback amplitude, with one renderer and an explicit flat fallback when playback truth is unavailable.

**Architecture:** The TypeScript playback queue decodes each audio file into a fixed-window RMS envelope and embeds it in the speaking state event after the player starts. The Swift socket boundary validates that payload, `VoiceState` anchors it to a local clock, and a single SwiftUI waveform resolves either live RMS or clock-indexed playback RMS into one monotonic seven-bar shape.

**Tech Stack:** Bun/TypeScript, ffmpeg PCM decoding, Swift 5.9, SwiftUI, XCTest, NDJSON Unix-socket protocol.

---

### Task 1: Build deterministic playback-amplitude envelopes

**Files:**
- Create: `src/playback-amplitude.ts`
- Create: `src/__tests__/playback-amplitude.test.ts`

**Step 1: Write the failing pure-envelope tests**

Add tests for the wished-for API:

```ts
import {
  PLAYBACK_AMPLITUDE_INTERVAL_MS,
  buildPlaybackAmplitudeEnvelope,
  extractPlaybackAmplitudeEnvelope,
} from "../playback-amplitude";

expect(buildPlaybackAmplitudeEnvelope(pcm16([0, 0, 0, 0]), 40, 50)).toEqual({
  source: "decoded-rms",
  sample_interval_ms: 50,
  samples: [0],
});

const envelope = buildPlaybackAmplitudeEnvelope(
  pcm16([1000, 1000, 8000, 8000]),
  40,
  50,
);
expect(envelope.samples[1]).toBeGreaterThan(envelope.samples[0]);
```

Also inject a decoder runner that fails and assert
`{ source: "unavailable", sample_interval_ms: 50, samples: [] }`.

**Step 2: Run the test to verify RED**

Run: `bun test src/__tests__/playback-amplitude.test.ts`

Expected: FAIL because `src/playback-amplitude.ts` does not exist.

**Step 3: Implement the minimal envelope module**

Export:

```ts
export const PLAYBACK_AMPLITUDE_INTERVAL_MS = 50;
export type PlaybackAmplitudeEnvelope =
  | { source: "decoded-rms"; sample_interval_ms: number; samples: number[] }
  | { source: "unavailable"; sample_interval_ms: number; samples: [] };

export function buildPlaybackAmplitudeEnvelope(
  pcm16: Uint8Array,
  sampleRate: number,
  intervalMs?: number,
): PlaybackAmplitudeEnvelope;

export function extractPlaybackAmplitudeEnvelope(
  audioFile: string,
  runDecoder?: PlaybackAmplitudeDecoder,
): PlaybackAmplitudeEnvelope;
```

The decoder invokes `ffmpeg -v error -i <file> -vn -ac 1 -ar 1000 -f s16le pipe:1`.
Compute RMS per 50 ms window, convert to dBFS, clamp/map against a fixed floor,
and never normalize against a clip-local peak.

**Step 4: Run the test to verify GREEN**

Run: `bun test src/__tests__/playback-amplitude.test.ts`

Expected: all playback-amplitude tests pass with 0 failures.

**Step 5: Commit**

```bash
git add src/playback-amplitude.ts src/__tests__/playback-amplitude.test.ts
git commit -m "feat: derive truthful playback amplitude"
```

### Task 2: Ship the envelope with every speaking event

**Files:**
- Modify: `src/socket-protocol.ts`
- Modify: `src/tts.ts`
- Modify: `src/__tests__/socket-protocol.test.ts`
- Modify: `src/__tests__/playback-queue.test.ts`
- Modify: `src/__tests__/socket-handlers-idempotency.test.ts`

**Step 1: Write failing schema and playback tests**

Add a TypeScript serialization test for:

```ts
const event: SocketEvent = {
  type: "state",
  state: "speaking",
  text: "truth",
  voice: "jenny",
  playback_amplitude: {
    source: "decoded-rms",
    sample_interval_ms: 50,
    samples: [0, 0.5, 1],
  },
};
```

In queue tests, inject an envelope extractor, start playback, and assert the
speaking broadcast occurs after the spawn and carries the exact envelope.
Cover decode failure and cached replay, where the speaking event explicitly
carries `source: "unavailable"` or a decoded cached-file envelope.

**Step 2: Run targeted tests to verify RED**

Run: `bun test src/__tests__/socket-protocol.test.ts src/__tests__/playback-queue.test.ts src/__tests__/socket-handlers-idempotency.test.ts`

Expected: FAIL because the event type and queue metadata do not expose playback amplitude.

**Step 3: Implement schema and queue wiring**

- Add `PlaybackAmplitudeEnvelope` to `StateEvent` as optional
  `playback_amplitude`.
- Add an injectable envelope extractor to the queue manager's test seam.
- Compute the envelope once per enqueue and retain it on the job.
- Spawn the player first, set the queue start timestamp, then broadcast the
  speaking state with the envelope.
- Keep subtitle, clip-marker, queue progress, priority, engine metadata, and
  speaker-output gates unchanged.
- Replays use the same enqueue path, so cached files are decoded without a ring
  schema migration.

**Step 4: Run targeted tests to verify GREEN**

Run: `bun test src/__tests__/socket-protocol.test.ts src/__tests__/playback-queue.test.ts src/__tests__/socket-handlers-idempotency.test.ts`

Expected: targeted tests pass with 0 failures.

**Step 5: Run TTS regression coverage**

Run: `bun test src/__tests__/tts.test.ts src/__tests__/speaker-output-gate.test.ts src/__tests__/stop-queue-edge-cases.test.ts`

Expected: regression tests pass with 0 failures.

**Step 6: Commit**

```bash
git add src/socket-protocol.ts src/tts.ts src/__tests__/socket-protocol.test.ts src/__tests__/playback-queue.test.ts src/__tests__/socket-handlers-idempotency.test.ts
git commit -m "feat: publish playback amplitude with speech"
```

### Task 3: Parse and clock playback truth in VoiceBar

**Files:**
- Create: `flow-bar/Sources/VoiceBarUI/PlaybackAmplitude.swift`
- Create: `flow-bar/Tests/VoiceBarUITests/PlaybackAmplitudeTests.swift`
- Modify: `flow-bar/Sources/VoiceBar/SocketProtocol.swift`
- Modify: `flow-bar/Sources/VoiceBar/SocketServer.swift`
- Create: `flow-bar/Tests/VoiceBarTests/SocketProtocolTests.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceState.swift`
- Modify: `flow-bar/Tests/VoiceBarUITests/VoiceStateTests.swift`

**Step 1: Write failing model and protocol tests**

Define the desired UI model in tests:

```swift
let envelope = PlaybackAmplitudeEnvelope(
    source: .decodedRMS,
    sampleIntervalMilliseconds: 50,
    samples: [0, 0.4, 0.9]
)
XCTAssertEqual(envelope.level(elapsedMilliseconds: 0), 0)
XCTAssertEqual(envelope.level(elapsedMilliseconds: 75), 0.4)
XCTAssertEqual(envelope.level(elapsedMilliseconds: 500), 0)
```

Add executable-target protocol tests that parse a speaking dictionary, reject
nonpositive intervals/non-numeric samples, clamp numeric samples, and preserve
`source: unavailable` with an empty list.

Add state tests that inject an envelope and clock into a speaking event, advance
the clock, assert the selected level changes, then send playback idle and assert
the envelope is cleared.

**Step 2: Run Swift tests to verify RED**

Run: `swift test --package-path flow-bar --filter 'PlaybackAmplitudeTests|SocketProtocolTests|VoiceStateTests'`

Expected: compile FAIL because the playback model/parser/state fields do not exist.

**Step 3: Implement model, parser, dispatch, and state clock**

- Add an equatable `PlaybackAmplitudeEnvelope` with explicit source enum,
  interval, samples, and a bounds-safe level lookup.
- In `SocketProtocol.swift`, parse `playback_amplitude` from speaking events and
  return the VoiceBarUI model.
- In `SocketServer`, parse on the socket boundary and pass the typed model beside
  the raw dictionary to `VoiceState.handleEvent`.
- In `VoiceState`, store the envelope and an injected reference-time clock when
  speaking begins; expose a `playbackAudioLevel(at:)` lookup; clear both on idle,
  disconnect, stop/cancel, and error/reset paths.

**Step 4: Run targeted Swift tests to verify GREEN**

Run: `swift test --package-path flow-bar --filter 'PlaybackAmplitudeTests|SocketProtocolTests|VoiceStateTests'`

Expected: targeted tests pass with 0 failures.

**Step 5: Commit**

```bash
git add flow-bar/Sources/VoiceBarUI/PlaybackAmplitude.swift flow-bar/Tests/VoiceBarUITests/PlaybackAmplitudeTests.swift flow-bar/Sources/VoiceBar/SocketProtocol.swift flow-bar/Sources/VoiceBar/SocketServer.swift flow-bar/Tests/VoiceBarTests/SocketProtocolTests.swift flow-bar/Sources/VoiceBarUI/VoiceState.swift flow-bar/Tests/VoiceBarUITests/VoiceStateTests.swift
git commit -m "feat: clock playback amplitude in VoiceBar"
```

### Task 4: Converge to one truthful waveform renderer

**Files:**
- Modify: `flow-bar/Sources/VoiceBarUI/WaveformView.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/BarView.swift`
- Modify: `flow-bar/Tests/VoiceBarUITests/WaveformViewTests.swift`
- Modify: `flow-bar/Tests/VoiceBarUITests/BarViewSnapshotArtifactTests.swift`

**Step 1: Replace old tests with failing truth tests**

Write tests for one metrics API:

```swift
XCTAssertEqual(WaveformMetrics.normalizedLevel(audioLevel: nil, index: 3, barCount: 7), 0)
XCTAssertEqual(WaveformMetrics.normalizedLevel(audioLevel: 0, index: 3, barCount: 7), 0)
XCTAssertGreaterThan(
    WaveformMetrics.normalizedLevel(audioLevel: 0.8, index: 3, barCount: 7),
    WaveformMetrics.normalizedLevel(audioLevel: 0.2, index: 3, barCount: 7)
)
```

Prove identical inputs yield identical heights regardless of time, and prove
every bar is monotonic from quiet to loud. Update artifact-state setup to
provide a deterministic playback envelope for speaking snapshots.

**Step 2: Run waveform tests to verify RED**

Run: `swift test --package-path flow-bar --filter WaveformViewTests`

Expected: FAIL because the single metrics API does not exist and old synthetic modes remain.

**Step 3: Implement one renderer**

- Remove `WaveformMode`, idle breathing, speech simulation, processing motion,
  and all time-based sine/jitter.
- Make `WaveformView` accept a current-level provider/source plus a state color.
- Use one static center-weighted, monotonic amplitude-to-height function.
- Recording passes only live `state.audioLevel`, ignoring `speechDetected` for
  geometry.
- Speaking passes `state.playbackAudioLevel(at:)` from the render timeline.
- Transcribing removes `WaveformView(mode: .processing)` and keeps the existing
  `ProcessingSpinner`/status presentation.

**Step 4: Run targeted tests to verify GREEN**

Run: `swift test --package-path flow-bar --filter 'WaveformViewTests|VoiceStateTests|BarViewSnapshotArtifactTests'`

Expected: targeted tests pass; artifact-only tests may skip only under their existing explicit gate.

**Step 5: Run the full Swift suite**

Run: `swift test --package-path flow-bar`

Expected: all runnable Swift tests pass with 0 failures.

**Step 6: Commit**

```bash
git add flow-bar/Sources/VoiceBarUI/WaveformView.swift flow-bar/Sources/VoiceBarUI/BarView.swift flow-bar/Tests/VoiceBarUITests/WaveformViewTests.swift flow-bar/Tests/VoiceBarUITests/BarViewSnapshotArtifactTests.swift
git commit -m "refactor: render one truthful waveform"
```

### Task 5: Verify the complete branch without resident disruption

**Files:**
- Verify existing code and generated artifacts only.

**Step 1: Run full Bun tests**

Run: `bun test`

Expected: all Bun tests pass with 0 failures.

**Step 2: Run full Swift tests**

Run: `swift test --package-path flow-bar`

Expected: all runnable Swift tests pass with 0 failures.

**Step 3: Build an isolated release app copy**

Run: `bash flow-bar/build-app.sh --install-path /tmp/VoiceBar-notch-w2.app --no-stop --no-relaunch`

Expected: release build/signing succeeds without touching `/Applications/VoiceBar.app`.

**Step 4: Run branch/corpus verification**

Run: `scripts/voicelayer-verify.sh --corpus 10`

Expected: verification succeeds on branch artifacts and isolated runtime paths.
If the script requests resident relaunch or F5 interaction, do not comply; use
its isolated-app options/pattern or record the exact hard-fence incompatibility.

**Step 5: Audit scope and protocol parity**

Run focused diffs and searches proving no F5/hotkey mechanism, engine-disclosure
metadata, install path, launchd state, or resident process was changed.

### Task 6: Produce the side-by-side visual receipt

**Files:**
- Create under an isolated artifact directory outside the resident app.

**Step 1: Launch only the isolated app and daemon/socket**

Use `/tmp/VoiceBar-notch-w2.app`, unique socket paths, and release configuration.
Never signal, replace, stop, or relaunch the resident app/daemon; never use
`pkill`.

**Step 2: Exercise isolated dictation and voice_ask**

Capture one recording/listening sequence and one agent/speaking sequence where
the input audio has clearly varying real amplitude.

**Step 3: Capture the side-by-side artifact**

Record or assemble the two isolated app sequences side by side with paths and
state labels visible.

**Step 4: Inspect every artifact**

Open the image/video with an adequate visual tool. Verify both waveform rows
change with their corresponding audio and that silence/unavailable regions stay
flat. Record an R7 visual verification receipt.

### Task 7: Publish the ready PR and report without merging

**Files:**
- Create: `/Users/etanheyman/Gits/orchestrator/docs.local/handoffs/2026-07-17-notch-w2-REPORT.md`
- Modify only if review fixes require code/test changes.

**Step 1: Re-run fresh completion verification**

Run full Bun, full Swift, isolated release build, corpus verification, and inspect
the final visual artifact again. Read complete outputs and count pass/fail/skip.

**Step 2: Run bounded CodeRabbit pre-commit review**

Run `coderabbit review --agent` with a three-minute bound. Fix critical findings;
if rate-limited, record the exact limitation and continue on fresh evidence.

**Step 3: Commit any remaining plan/artifact metadata changes**

Add only specific files. Do not commit ignored or machine-local runtime output.

**Step 4: Push and create a ready PR against main**

The PR body cites L1 §10 cluster 4 and GAPS §8.10, names the schema/fallback
contract, lists exact test evidence, links or describes the artifact path, and
states the isolated-app fence. Keep engine-disclosure fields untouched.

**Step 5: Invoke and read reviewers**

Request `@codex review` and `@cursor @bugbot review` (plus CodeRabbit if
available). Read all comments/checks, investigate findings, address every
critical/major/high item, push fixes, and request re-review. Do not merge.

**Step 6: Write and verify the required report**

Write the absolute report path with PR URL, exact test counts, artifact path,
review status, and final line `NOTCH_W2_DONE`. Read it back in full.

**Step 7: Store the milestone**

Store WHAT changed and WHY in BrainLayer with the PR URL and verification
evidence, then search to verify storage.
