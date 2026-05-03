# Waveform Visualization Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Show a live recording waveform in VoiceBar using local microphone levels from an `AVAudioEngine` tap.

**Architecture:** Keep the existing `WaveformView` and `VoiceState.audioLevel` model. Add a small app-local audio level monitor that samples the microphone while VoiceBar is recording, normalize that level into the existing waveform input, and stop/reset cleanly when recording ends or transitions out of record mode.

**Tech Stack:** Swift, SwiftUI, AppKit, AVFoundation, XCTest

---

### Task 1: Add the failing state-level tests

**Files:**
- Modify: `flow-bar/Tests/VoiceBarTests/VoiceStatePasteTests.swift`
- Modify: `flow-bar/Sources/VoiceBar/VoiceState.swift`

**Step 1: Write the failing test**

Add tests for:
- local recording level overrides socket level while recording
- local recording level is ignored outside recording mode
- recording stop/reset clears the current level

**Step 2: Run test to verify it fails**

Run: `swift test --package-path flow-bar --filter VoiceStatePasteTests`
Expected: FAIL because `VoiceState` has no local recording level API yet.

**Step 3: Write minimal implementation**

Add a minimal `VoiceState` API for:
- setting a local recording level during active recording
- clearing that level on stop/cancel/idle/transcribing
- exposing the effective `audioLevel` used by the UI

**Step 4: Run test to verify it passes**

Run: `swift test --package-path flow-bar --filter VoiceStatePasteTests`
Expected: PASS

**Step 5: Commit**

```bash
git add flow-bar/Sources/VoiceBar/VoiceState.swift flow-bar/Tests/VoiceBarTests/VoiceStatePasteTests.swift
git commit -m "feat: add VoiceBar local recording level state"
```

### Task 2: Add the local microphone level monitor

**Files:**
- Create: `flow-bar/Sources/VoiceBar/AudioLevelMonitor.swift`
- Create: `flow-bar/Tests/VoiceBarTests/AudioLevelMonitorTests.swift`
- Modify: `flow-bar/Sources/VoiceBar/VoiceBarApp.swift`

**Step 1: Write the failing test**

Add a small unit test for the level-normalization helper in the new monitor file so the monitor has a deterministic seam.

**Step 2: Run test to verify it fails**

Run: `swift test --package-path flow-bar --filter AudioLevelMonitorTests`
Expected: FAIL because the helper/monitor test target does not exist yet.

**Step 3: Write minimal implementation**

Implement:
- `AudioLevelMonitor` backed by `AVAudioEngine`
- input-node tap that computes RMS from the microphone buffer
- normalization into a 0...1 level suitable for `WaveformView`
- callbacks into `VoiceState` on the main queue
- handle microphone permission / engine start failure paths without crashing, and ensure the app bundle keeps `NSMicrophoneUsageDescription`

Wire it in `VoiceBarApp` so monitor start/stop follows `voiceState.onModeChange`, and clear/reset the level cleanly when monitoring cannot start.

**Step 4: Run test to verify it passes**

Run: `swift test --package-path flow-bar --filter AudioLevelMonitorTests`
Expected: PASS

**Step 5: Commit**

```bash
git add flow-bar/Sources/VoiceBar/AudioLevelMonitor.swift flow-bar/Sources/VoiceBar/VoiceBarApp.swift flow-bar/Tests/VoiceBarTests/AudioLevelMonitorTests.swift
git commit -m "feat: add VoiceBar microphone waveform monitor"
```

### Task 3: Verify recording UI behavior stays correct

**Files:**
- Modify: `flow-bar/Sources/VoiceBar/BarView.swift` (only if needed)
- Modify: `flow-bar/Sources/VoiceBar/WaveformView.swift` (only if needed)
- Modify: `flow-bar/Tests/VoiceBarTests/VoiceBarPresentationTests.swift` (only if needed)

**Step 1: Write the failing test**

If the new local levels expose a rendering/state issue, add the smallest failing test around that behavior.

**Step 2: Run test to verify it fails**

Run the targeted package test command for that new test.

**Step 3: Write minimal implementation**

Only adjust the waveform rendering if the current `WaveformView` needs smoothing/clamping tweaks for live mic data.

**Step 4: Run test to verify it passes**

Run the targeted package test command again.

**Step 5: Commit**

```bash
git add flow-bar/Sources/VoiceBar/BarView.swift flow-bar/Sources/VoiceBar/WaveformView.swift flow-bar/Tests/VoiceBarTests/VoiceBarPresentationTests.swift
git commit -m "fix: tune VoiceBar live waveform rendering"
```

### Task 4: Full verification, build, launch, and PR

**Files:**
- Modify: `~/Gits/orchestrator/collab/native-apps-march30.md`

**Step 1: Run package tests**

Run: `swift test --package-path flow-bar`
Expected: PASS

**Step 2: Run repo tests**

Run: `bun test`
Expected: PASS

**Step 3: Build the app**

Run: `bash flow-bar/build-app.sh`
Expected: build succeeds and refreshes `/Applications/VoiceBar.app`

**Step 4: Launch the app**

Run: `open -a /Applications/VoiceBar.app`
Expected: app process is running and `/tmp/voicelayer.sock` exists

**Step 5: Push and create PR**

```bash
git push -u origin codex/p3-waveform
gh pr create --base main --head codex/p3-waveform --title "feat: add VoiceBar recording waveform monitor"
```
