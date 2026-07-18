# VoiceBar M1 Gold Renderer Restoration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Restore the exact `5beaf34` F5 waveform formula for recording, ask listening, and speaking while retaining the current truthful level sources and all non-rendering work.

**Architecture:** `WaveformView` will consume one current normalized magnitude instead of spatial time slices. A single shared animated envelope applies the historical `0.06s` attack and `0.40s` release, then every bar is computed with the exact golden-ratio phase, center weighting, base/envelope coefficients, 7 Hz shimmer, and 12 Hz jitter from `5beaf34`. Recording reads `VoiceState.recordingWaveformLevel`; speaking reads `VoiceState.playbackAudioLevel()`. Transcribing restores the historical spinner leading indicator and historical processing-bar formula without changing state or archive wiring.

**Tech Stack:** SwiftUI, XCTest, Swift Package Manager, Bun, VoiceLayer corpus verifier.

---

## Task 1: Pin the historical formula with RED tests

**Files:**
- Modify: `flow-bar/Tests/VoiceBarUITests/WaveformViewTests.swift`

1. Replace Round-3B time-slice assertions with a formula-equivalence test that independently calculates the `5beaf34` result for all seven bars using:
   - `phi = 1.618033988749895`
   - `centerWeight = 1 - normalizedDistance * 0.35`
   - `fast = sin(time * 7 + phase * 2.5) * 0.08`
   - `jitter = sin(time * 12 + phase * 6) * 0.05`
   - `motionScale = 0.4 + level * 0.6`
   - `base = 0.04 + level * 0.12`
   - `envelope = pow(level, 0.9) * centerWeight`
   - `base + envelope * 0.82 + (fast + jitter) * motionScale`
2. Add tests for listening damping `×0.7`, attack `0.06s`, release `0.40s`, and exact flat output at zero.
3. Keep a no-travel gate: changing historical samples while the current magnitude and time stay fixed must not change any bar; time evolution must preserve per-bar phi shimmer instead of moving sample chronology across space.
4. Add source-contract assertions that recording and both speaking call sites use scalar truth (`recordingWaveformLevel`, `playbackAudioLevel`) and that transcribing has `ProcessingSpinner` as its leading indicator.
5. Run `swift test --package-path flow-bar --filter WaveformViewTests` and confirm the new API/formula tests fail for the current Round-3B renderer.

## Task 2: Restore the gold renderer with current truth inputs

**Files:**
- Modify: `flow-bar/Sources/VoiceBarUI/WaveformView.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/BarView.swift`

1. Remove `.centerOutHistory` and the recording time-slice initializer.
2. Render audio-driven states from one current level through one shared smoothed envelope.
3. Copy the `5beaf34` `audioLevelDriven` arithmetic exactly. Clamp only at the same normalized-output boundary; return exact zero when the truthful envelope is zero so recording has no synthetic idle motion.
4. Apply listening damping before the formula and keep attack/release constants at `0.06/0.40`.
5. Preserve the gold per-state glow treatment: listening `0.25/3`, detected speech `0.45/5`, and processing `0.35/4` for opacity/radius.
6. Wire recording to `state.recordingWaveformLevel`; wire both speaking locations to `state.playbackAudioLevel()`. Do not modify `VoiceState`, `PlaybackAmplitude`, `WaveformEnvelopeHistory`, or TypeScript.
7. Restore `ProcessingSpinner()` in the transcribing leading-indicator branch and copy `5beaf34` processing-bar arithmetic.
8. Run the focused tests until GREEN; do not tune gain or formula constants from source-only evidence.

## Task 3: Verify and publish the same PR seam

**Files:**
- Modify: PR #351 body
- Modify: `/Users/etanheyman/Gits/orchestrator/collab/2026-07-17-voicelayer-notch-w1-w2.md`

1. Run focused Swift tests, full Swift tests, isolated serialized Bun tests, typecheck, verifier syntax, and `git diff --check`.
2. Confirm protected amplitude, geometry, archive, timeout, and input files remain byte-identical.
3. Run bounded local CodeRabbit review and address renderer findings.
4. Commit and run `bash scripts/voicelayer-verify.sh --corpus 10` on the exact committed SHA.
5. Push `fix/voice-ask-path-reliability`, repin PR #351 to the exact runtime marker, and request exact-head Codex/CodeRabbit review. Do not merge or touch the resident stack.
6. Post RED/GREEN counts, source fences, artifact path, and the honest visual boundary: code/formula equivalence is verified; Etan’s same-Mac M1 side-by-side remains the perceptual acceptance gate.
