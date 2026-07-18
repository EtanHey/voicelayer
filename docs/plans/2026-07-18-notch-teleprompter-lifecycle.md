# Native Notch Teleprompter Lifecycle Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Pin top-first teleprompter layout, authoritative whole-script timing, and hover-aware retained read-back dismissal.

**Architecture:** Keep timing/layout policies in `TeleprompterView.swift` and keep retained-readback dismissal solely in the app-owned, pointer-aware `RetainedReadbackDismissalCoordinator`. `BarView` renders the native surface but does not own a competing dismissal timer. Do not modify W2 truth, renderer, archive, or socket files.

**Tech Stack:** Swift 6, SwiftUI, Observation, XCTest, Swift concurrency.

---

### Task 1: RED — authoritative teleprompter pacing and top start

**Files:**
- Modify: `flow-bar/Tests/VoiceBarUITests/TeleprompterContentModelTests.swift`
- Test: `flow-bar/Tests/VoiceBarUITests/TeleprompterContentModelTests.swift`

**Step 1: Write failing tests**

Add tests that require mismatched phonetic boundaries to retain original display words, produce timed monotonic offsets, and end at the final server boundary endpoint. Timing weight for each display word is `clamp(0.28 + characterCount × 0.015, 0.22, 0.38)`, plus `0.10` for `. ! ?` or `0.05` for `, ; :`. For each word, its start and end are the rounded cumulative-weight fractions of the first-boundary-start-to-final-boundary-end interval; the last word ends exactly at the final boundary endpoint. Assert deterministic intermediate offsets, not only monotonicity and the endpoint. Add contracts for `.top` initial viewport alignment and zero playback startup delay.

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

### Task 3: RED — pointer-aware read-back lifecycle

**Files:**
- Modify: `flow-bar/Tests/VoiceBarTests/AppLifecycleTests.swift`
- Test: `flow-bar/Tests/VoiceBarTests/AppLifecycleTests.swift`

**Step 1: Write failing async tests**

Require unattended read-back to dismiss after a short injected delay, actual pointer presence inside the active notch shape to preserve read-back, and pointer departure to receive a fresh full delay. Assert that the app-level coordinator is the sole automatic dismissal owner.

**Step 2: Run the focused test and verify RED**

Run: `swift test --package-path flow-bar --filter AppLifecycleTests`

Expected: FAIL because the pointer-aware coordinator and single-owner wiring do not exist.

### Task 4: GREEN — single pointer-aware lifecycle owner

**Files:**
- Modify: `flow-bar/Sources/VoiceBar/RetainedReadbackDismissalCoordinator.swift`
- Modify: `flow-bar/Sources/VoiceBar/VoiceBarApp.swift`
- Test: `flow-bar/Tests/VoiceBarTests/AppLifecycleTests.swift`

**Step 1: Implement the minimum lifecycle**

Add one cancellable task to the app-owned coordinator. At each 800 ms boundary, evaluate the current screen pointer against the current shape-aware active hit region; reschedule while inside and call the existing `dismissRetainedTeleprompter()` only while outside. `BarView` must not schedule or perform automatic dismissal.

**Step 2: Run the focused tests and verify GREEN**

Run: `swift test --package-path flow-bar --filter 'TeleprompterContentModelTests|AppLifecycleTests'`

Expected: PASS.

### Task 5: Full verification and exact-head proof

**Files:**
- Update: `<orchestrator-repo>/collab/2026-07-17-voicelayer-notch-w1-w2.md`
- Update: `<orchestrator-repo>/docs.local/handoffs/2026-07-17-notch-w1-native-port-REPORT.md`

**Step 1: Run verification**

Run full Swift, Bun, typecheck, diff check, and isolated corpus verification. Audit that W2 protected files remain unchanged.

**Step 2: Commit and push**

Commit the behavior slice, push PR #352, repin `Verified-Runtime`, and keep merge blocked until #351 merges and W1 rebases.
