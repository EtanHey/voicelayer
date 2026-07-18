# Native Notch Teleprompter Lifecycle Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Pin top-first teleprompter layout, authoritative whole-script timing, and hover-aware retained read-back dismissal.

**Architecture:** Keep timing/layout policies in `TeleprompterView.swift`, keep the dismissal task in the persistent notch presentation model, and let `BarView` connect hover/read-back state to the existing VoiceState dismissal action. Do not modify W2 truth, renderer, archive, or socket files.

**Tech Stack:** Swift 6, SwiftUI, Observation, XCTest, Swift concurrency.

---

### Task 1: RED — authoritative teleprompter pacing and top start

**Files:**
- Modify: `flow-bar/Tests/VoiceBarUITests/TeleprompterContentModelTests.swift`
- Test: `flow-bar/Tests/VoiceBarUITests/TeleprompterContentModelTests.swift`

**Step 1: Write failing tests**

Add tests that require mismatched phonetic boundaries to retain original display words, produce timed monotonic offsets, and end at the final server boundary endpoint. Add contracts for `.top` initial viewport alignment and zero playback startup delay.

**Step 2: Run the focused test and verify RED**

Run: `swift test --package-path flow-bar --filter TeleprompterContentModelTests`

Expected: FAIL because the mismatched display words have no offsets and the new policy members do not exist.

### Task 2: GREEN — resampled schedule and top-first viewport

**Files:**
- Modify: `flow-bar/Sources/VoiceBarUI/TeleprompterView.swift`
- Test: `flow-bar/Tests/VoiceBarUITests/TeleprompterContentModelTests.swift`

**Step 1: Implement the minimum policy**

Preserve exact one-to-one boundary mapping. For mismatched timed boundaries, distribute display-word timing weights across the first-boundary to final-boundary interval. Top-align the viewport and remove the unconditional 300 ms startup wait.

**Step 2: Run the focused test and verify GREEN**

Run: `swift test --package-path flow-bar --filter TeleprompterContentModelTests`

Expected: PASS.

### Task 3: RED — hover-aware read-back lifecycle

**Files:**
- Modify: `flow-bar/Tests/VoiceBarUITests/VoiceBarNotchViewTests.swift`
- Test: `flow-bar/Tests/VoiceBarUITests/VoiceBarNotchViewTests.swift`

**Step 1: Write failing async tests**

Require unattended read-back to dismiss after a short injected delay, hover re-entry to cancel dismissal, a later leave to receive a fresh full delay, and non-read-back states to remain untouched.

**Step 2: Run the focused test and verify RED**

Run: `swift test --package-path flow-bar --filter VoiceBarNotchViewTests`

Expected: FAIL because the presentation model has no retained-read-back lifecycle API.

### Task 4: GREEN — persistent lifecycle controller and BarView wiring

**Files:**
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceBarNotchPresentationModel.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/BarView.swift`
- Test: `flow-bar/Tests/VoiceBarUITests/VoiceBarNotchViewTests.swift`

**Step 1: Implement the minimum lifecycle**

Add one cancellable task to the persistent presentation model. `BarView` updates it on appear, hover changes, read-back changes, and disappearance. Call the existing `dismissRetainedTeleprompter()` only after 800 ms continuously unattended.

**Step 2: Run the focused tests and verify GREEN**

Run: `swift test --package-path flow-bar --filter 'TeleprompterContentModelTests|VoiceBarNotchViewTests'`

Expected: PASS.

### Task 5: Full verification and exact-head proof

**Files:**
- Update: `/Users/etanheyman/Gits/orchestrator/collab/2026-07-17-voicelayer-notch-w1-w2.md`
- Update: `/Users/etanheyman/Gits/orchestrator/docs.local/handoffs/2026-07-17-notch-w1-native-port-REPORT.md`

**Step 1: Run verification**

Run full Swift, Bun, typecheck, diff check, and isolated corpus verification. Audit that W2 protected files remain unchanged.

**Step 2: Commit and push**

Commit the behavior slice, push PR #352, repin `Verified-Runtime`, and keep merge blocked until #351 merges and W1 rebases.

