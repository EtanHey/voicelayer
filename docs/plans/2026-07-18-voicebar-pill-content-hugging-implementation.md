# VoiceBar Pill Content-Hugging Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make compact recording and transcribing pills hug their visible content while keeping recording-dot padding identical across ask, F5, and pill-press entry modes.

**Architecture:** Add one deterministic compact-pill metrics seam in `Theme.swift`; both the SwiftUI pill and AppKit panel layout consume its width, padding, and spacing. Preserve fixed teleprompter/queue envelopes and preserve the accepted waveform renderer byte-for-byte.

**Tech Stack:** Swift 6, SwiftUI, AppKit text metrics, XCTest, existing VoiceLayer corpus verifier.

---

### Task 1: Pin the geometry regression with RED tests

**Files:**
- Modify: `flow-bar/Tests/VoiceBarUITests/VoiceBarPanelLayoutTests.swift`

**Step 1: Write the failing tests**

- Assert recording metrics use the same `10`-point horizontal inset with and without the VAD hold control.
- Assert VAD width exceeds PTT/manual width by exactly one action-button width plus one internal button gap.
- Assert transcribing width is the exact sum of visible waveform, optional measured label, cancel button, declared gaps, and symmetric insets.
- Assert short and long transcribing statuses produce different content-hugging widths within the panel cap.

**Step 2: Run the focused tests to verify RED**

Run: `swift test --package-path flow-bar --filter VoiceBarPanelLayoutTests`

Expected: FAIL because the shared pill-metrics API is absent and the old recording/transcribing widths are fixed/minimum-padded.

### Task 2: Implement the minimal shared metrics seam

**Files:**
- Modify: `flow-bar/Sources/VoiceBarUI/Theme.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/BarView.swift`

**Step 1: Add content-derived metrics**

- Add a small value type containing `width`, `horizontalPadding`, and `contentSpacing`.
- Compute recording width from the indicator, waveform, visible action-button count, and gaps.
- Compute transcribing width from the waveform, measured label, cancel button, and gaps.
- Keep existing fixed widths for purposeful teleprompter/queue envelopes and unrelated modes.

**Step 2: Make BarView consume the same metrics**

- Replace the recording-only `5/14` padding and `4/8` spacing branches with the shared metrics values.
- Keep waveform initializers and renderer code unchanged.

**Step 3: Run focused tests to verify GREEN**

Run: `swift test --package-path flow-bar --filter VoiceBarPanelLayoutTests`

Expected: PASS.

Run: `swift test --package-path flow-bar --filter BarViewClickabilityTests`

Expected: PASS.

### Task 3: Verify, review, and publish the exact head

**Files:**
- Verify: `flow-bar/Sources/VoiceBarUI/WaveformView.swift`
- Verify: `flow-bar/Tests/VoiceBarUITests/WaveformViewTests.swift`
- Update externally: PR #351 and the W1/W2 contract file.

**Step 1: Run full verification**

Run: `swift test --package-path flow-bar`

Run: `bun test --max-concurrency=1 --reporter=dot`

Run: `bun run typecheck`

Run: `git diff --check`

**Step 2: Run the bounded local review gate**

Run: `timeout 180 coderabbit review --agent`

Expected: zero undispositioned critical findings, or an explicit availability receipt plus fallback review.

**Step 3: Commit and certify the exact head**

Commit only the two plan files, production geometry files, and layout tests. Then run `bash scripts/voicelayer-verify.sh --corpus 10` and read the generated exact-head artifact completely.

**Step 4: Push and update the existing PR**

Push `fix/voice-ask-path-reliability`, repin the PR body to the new `Verified-Runtime` SHA, request exact-head bot reviews, disposition findings, and append the evidence to `/Users/etanheyman/Gits/orchestrator/collab/2026-07-17-voicelayer-notch-w1-w2.md`.

**Step 5: Stop without merge or resident changes**

Report the exact head, tests, corpus artifact, waveform hash fence, and the honest visual-verdict boundary.
