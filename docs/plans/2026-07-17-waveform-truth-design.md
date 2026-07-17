# VoiceBar Waveform Truth Design

## Context and contract

L1 §10 build-contract cluster 4, merged in orchestrator PR #93, requires the
recording/listening and agent/speaking waveforms to use real amplitude. This
lane implements the waveform-truth half only. It does not change F5 gesture,
recording, dictation, transcription, paste, engine selection, or engine
disclosure behavior.

Today recording emits RMS about every 100 ms (`src/input.ts:1760-1767`) and
VoiceBar stores that value as its live `audioLevel`
(`flow-bar/Sources/VoiceBarUI/VoiceState.swift:206-218,977-982`). Speaking has
no playback-amplitude field in the state schema
(`src/socket-protocol.ts:20-37`). The speaking view therefore renders the
synthetic idle waveform, while transcribing renders a second synthetic mode
(`flow-bar/Sources/VoiceBarUI/BarView.swift:285-365`). The renderer contains
separate idle, listening, speech-detected, and processing paths; idle and the
no-level speech fallback are synthetic, and even audio-driven bars add
time-based sine motion (`flow-bar/Sources/VoiceBarUI/WaveformView.swift:84-115,130-228`).

The playback queue already owns the correct clock boundary: it launches the
player, records `startedAt`, and maintains progress from that timestamp
(`src/tts.ts:846-865,1004-1026`). New TTS and replay both pass an audio file
through `playAudioNonBlocking` (`src/tts.ts:1352-1367`;
`src/socket-handlers.ts:93-109`), so one queue-level envelope path covers every
engine and cached replay.

## Considered approaches

### 1. Precomputed RMS envelope in the speaking state event (chosen)

Decode the synthesized or cached audio file asynchronously when its queue item
is eligible to start, compute a compact fixed-window RMS envelope, and attach
it to the speaking state event when playback starts. VoiceBar indexes the
samples from its receipt time.

This uses the queue's existing start/stop/barge-in lifecycle, sends one bounded
payload instead of continuous IPC traffic, and covers edge-TTS, cloned voices,
fallbacks, and replay without an audio tap.

### 2. Stream playback audio-level events

The daemon could publish one level event every 50-100 ms. This would reuse the
recording event shape, but it adds a second progress timer, higher IPC volume,
and more cancellation/reset behavior for stop, barge-in, queue expiry, and
disconnects.

### 3. Tap runtime system output

VoiceBar could capture the output device or reroute playback through an
AVAudioEngine graph. That observes the final device signal, but `afplay` exposes
no meter, and system-output capture introduces permissions, routing, and
resident-device risk that are disproportionate to this contract.

## Truth contract

The speaking state event gains an optional `playback_amplitude` object:

```json
{
  "source": "decoded-rms",
  "sample_interval_ms": 50,
  "samples": [0.0, 0.18, 0.62, 0.41]
}
```

- `samples` are clamped normalized RMS values in `[0, 1]`.
- Samples use fixed 50 ms windows. The sampling interval is explicit so the
  client never assumes a hidden rate.
- RMS-to-display mapping uses a fixed dBFS floor, never per-clip peak
  normalization. A quiet clip therefore remains visually quieter than a loud
  clip.
- Decoder output is capped at 20 minutes of 1 kHz PCM16 (2,400,000 bytes), the
  serialized envelope at 24,000 samples, and decoder wall time at 30 seconds.
  The Swift socket boundary independently rejects envelopes above the same
  24,000-sample protocol ceiling before copying or retaining their samples.
  Window intervals must resolve to an exact whole PCM sample count.
- The event is emitted immediately after the audio player process starts.
  VoiceBar records its local monotonic-uptime receipt clock and uses that same
  clock domain on each renderer refresh to compute
  `floor(elapsed_ms / sample_interval_ms)` to select the current level.
- Out-of-range elapsed time returns zero. Stop/idle clears the envelope.
- Playback queue progress and engine-disclosure metadata remain unchanged.

The TypeScript schema lives in `src/socket-protocol.ts`. The mirrored Swift
boundary parser lives in `flow-bar/Sources/VoiceBar/SocketProtocol.swift` and
produces the VoiceBarUI envelope model before dispatching the event to
`VoiceState`. Tests on both sides pin the field names, numeric validation,
clamping, and unavailable behavior.

## Envelope generation and fallback

`src/playback-amplitude.ts` owns two seams:

1. A pure PCM16-to-windowed-RMS function used by deterministic tests.
2. A file extractor that invokes `ffmpeg` to decode any supported TTS artifact
   to mono PCM16, then calls the pure function.

The queue prepares the envelope only when an item is eligible to start. This
keeps enqueue and `voice_speak` responses non-blocking and avoids decoding
items that remain behind active playback. Newly synthesized files are decoded
once before playback. Replay recomputes the envelope from the cached audio
file, so the ring-buffer schema does not need migration. Stop and critical
barge-in terminate any in-flight decoder before invalidating its queue slot;
late results cannot start superseded audio.

If the file cannot be decoded, the state event carries:

```json
{
  "source": "unavailable",
  "sample_interval_ms": 50,
  "samples": []
}
```

VoiceBar renders the minimum flat baseline. It never substitutes synthetic
motion. This fallback covers missing `ffmpeg`, corrupt cache entries, and any
future engine output format that the installed decoder cannot read.

## One waveform renderer

`WaveformView` becomes one seven-bar amplitude component. Its input is either a
live level or a playback envelope, but both resolve to one current amplitude
and one height function. State may select recording red or speaking blue; color
does not change the amplitude geometry.

- Every bar height is a monotonic function of current amplitude.
- Static center weighting gives the row a legible silhouette without claiming
  spectral information.
- No time-based sine, jitter, breathing, speech-detected boost, or no-level
  simulation remains.
- Recording no longer switches renderer behavior on the speech-detected bit;
  the real RMS level alone controls height.
- Speaking uses the clock-indexed playback envelope.
- Transcribing keeps its existing processing spinner and text, but removes the
  synthetic waveform because no audio exists in that phase.
- Missing, silent, expired, or unavailable input produces the same flat
  minimum baseline.

## Verification

TDD coverage will prove:

- PCM silence, quiet/loud ordering, window boundaries, clamping, and malformed
  decode fallback.
- TypeScript speaking serialization and Swift parsing use the same schema.
- Playback and cached replay ship truthful envelopes; decode failure is
  explicitly unavailable.
- VoiceState indexes the envelope by elapsed playback time and clears it on
  idle/stop.
- Recording and speaking share one monotonic bar-height calculation.
- The removed synthetic paths cannot animate without amplitude.

The lane then runs full Bun and Swift suites, the release app build, and
`scripts/voicelayer-verify.sh --corpus 10`. All runtime and visual work uses an
isolated release-built app path and isolated socket/environment, following the
PR #346 pattern. The resident `/Applications/VoiceBar.app` and resident daemon
are never stopped, relaunched, replaced, or signaled. The acceptance artifact
is a viewed side-by-side capture of isolated dictation and isolated
`voice_ask`, with both rows visibly following real amplitude.

## Non-goals

- Audible-onset teleprompter synchronization (cluster 2).
- HOLD-RECORDING control semantics (the other half of cluster 4).
- F5/dictation mechanism changes.
- TTS engine routing, pronunciation, queue priority, or disclosure changes.
- Resident app/daemon installation, restart, or verification.
