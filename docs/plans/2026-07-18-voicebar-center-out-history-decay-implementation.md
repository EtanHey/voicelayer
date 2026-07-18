# VoiceBar Center-Out History and Processing Pulse Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Render recording history as distinct center-out time slices with a
natural staggered decay, and remove phase travel from transcribing.

**Architecture:** Add one recording-only mapping to `WaveformView` that
reorders the existing seven normalized samples from newest-at-center outward.
Keep speaking on its accepted organic mapping, reuse the existing staggered bar
animation, and replace processing's distance-phase oscillator with an in-phase
center-weighted pulse.

**Tech Stack:** Swift 6, SwiftUI, XCTest, existing VoiceLayer corpus verifier.

---

## Task 1: Pin the renderer regressions with RED tests

**Files:**
- Modify: `flow-bar/Tests/VoiceBarUITests/WaveformViewTests.swift`

**Step 1: Add the center-out distinct-slice gate**

- Call the wished-for `WaveformMetrics.centerOutLevels` with seven distinct
  samples.
- Assert the newest sample is at bar 3, older samples follow bar order
  `[3, 2, 4, 1, 5, 0, 6]`, and every output includes the existing
  `centerWeight`.
- Assert an all-zero history remains exactly zero.

**Step 2: Add attack/release gates**

- Assert staggered attacks span 0.10–0.15 seconds.
- Assert staggered releases span 0.18–0.40 seconds and contain distinct values.

**Step 3: Strengthen the processing no-travel gate**

- Sample several adjacent frames.
- Assert mirrored bars remain equal, center never falls below the edges, and
  every bar moves in the same direction as the center.

**Step 4: Run RED**

Run:
`swift test --package-path flow-bar --filter WaveformViewTests`

Expected: FAIL because `centerOutLevels` does not exist, release still tops
out at 0.30 seconds, attack tops out at 0.20 seconds, and processing contains
opposed center/edge motion.

## Task 2: Implement the minimal renderer seam

**Files:**
- Modify: `flow-bar/Sources/VoiceBarUI/WaveformView.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/BarView.swift`

**Step 1: Add a recording-only render mapping**

- Add `recordingAudioLevels` initialization and a corresponding mapping case.
- Route that case through `centerOutLevels`.
- Leave `organicReactive` and speaking call sites unchanged.

**Step 2: Implement center-out sample placement**

- Reuse `normalizedLevels` for clamping and leading zero padding.
- Consume samples newest-first into destination order
  `[center, left-near, right-near, ...]`.
- Multiply each destination by its existing center weight.

**Step 3: Restore stagger bounds**

- Set maximum live attack to 0.15 seconds.
- Set maximum live release to 0.40 seconds.
- Ensure the recording mapping uses `transitionDuration`, not
  `reactiveTransitionDuration`.

**Step 4: De-travel processing**

- Replace the distance-phase oscillator with one shared pulse multiplied by
  center weight.
- Keep processing animated and immediately sampled at the TimelineView cadence.

**Step 5: Run GREEN**

Run:
`swift test --package-path flow-bar --filter WaveformViewTests`

Expected: PASS.

## Task 3: Verify and publish the exact head

**Files:**
- Verify unchanged: `flow-bar/Sources/VoiceBarUI/Theme.swift`
- Verify unchanged: `flow-bar/Tests/VoiceBarUITests/VoiceBarPanelLayoutTests.swift`
- Verify unchanged: `flow-bar/Sources/VoiceBarUI/VoiceState.swift`
- Verify unchanged: `flow-bar/Sources/VoiceBarUI/PlaybackAmplitude.swift`
- Verify unchanged: `flow-bar/Sources/VoiceBarUI/WaveformEnvelopeHistory.swift`
- Update: PR #351 body and orchestrator contract

**Step 1: Run focused and full verification**

- `swift test --package-path flow-bar --filter WaveformViewTests`
- `swift test --package-path flow-bar`
- isolated serialized `bun test --max-concurrency=1`
- `bun run typecheck`
- `bash -n scripts/voicelayer-verify.sh`
- `git diff --check`

**Step 2: Run review**

- `timeout 180 coderabbit review --agent`
- Disposition every finding against the Round-3B fences.

**Step 3: Commit and exact-head corpus**

- Commit the approved renderer/test/docs working set.
- Run `bash scripts/voicelayer-verify.sh --corpus 10`.
- Read the artifact and audit runner-owned temp/socket cleanup.

**Step 4: Push and report**

- Push `fix/voice-ask-path-reliability` to PR #351.
- Pin the exact `Verified-Runtime` marker in the PR body.
- Request Codex, Cursor/Bugbot, and CodeRabbit re-reviews.
- Post exact test, review, corpus, fence, and visual-verdict receipts to the
  contract file.
- Do not merge or touch the resident app.
