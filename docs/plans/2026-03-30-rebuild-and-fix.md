# Rebuild And Fix Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Restore reliable VoiceBar and BrainBar rebuilds and ship the requested VoiceBar paste/menu fixes.

**Architecture:** Keep the hotkey runtime logic mostly intact and fix the broken rebuild/install path by producing stable developer-signed app bundles. In VoiceBar, move menu behavior behind small testable helpers and make repaste timing explicit so context-menu-driven paste can wait for focus to settle before reactivating the target app.

**Tech Stack:** Swift, SwiftUI, AppKit, XCTest, shell build scripts, codesign

---

### Task 1: Add failing VoiceBar tests

**Files:**
- Modify: `flow-bar/Tests/VoiceBarTests/VoiceStatePasteTests.swift`
- Create: `flow-bar/Tests/VoiceBarTests/VoiceBarMenuTests.swift`

**Step 1: Write the failing tests**

- Add a test that requires repaste scheduling to use a non-zero settle delay while auto-paste remains immediate.
- Add tests that require a shared menu action list to expose `Settings`, `Hide for 1 hour`, `Paste last transcript`, and `Quit VoiceBar`, and verify each action callback fires.

**Step 2: Run test to verify it fails**

Run: `swift test --package-path flow-bar --filter 'VoiceStatePasteTests|VoiceBarMenuTests'`
Expected: FAIL because the helper types/properties do not exist yet.

### Task 2: Implement VoiceBar paste/menu behavior

**Files:**
- Modify: `flow-bar/Sources/VoiceBar/VoiceState.swift`
- Modify: `flow-bar/Sources/VoiceBar/VoiceBarApp.swift`
- Modify: `flow-bar/Sources/VoiceBar/BarView.swift`
- Create: `flow-bar/Sources/VoiceBar/VoiceBarMenu.swift`

**Step 1: Write minimal implementation**

- Add a small paste timing helper that distinguishes repaste from auto-paste.
- Delay repaste activation enough for menu dismissal, then activate the last target app and trigger the existing clipboard + `Cmd+V` paste path.
- Add a shared menu action model used by both the pill context menu and the menu bar dropdown.
- Implement `Settings`, `Hide for 1 hour`, `Paste last transcript`, and `Quit VoiceBar`.

**Step 2: Run test to verify it passes**

Run: `swift test --package-path flow-bar --filter 'VoiceStatePasteTests|VoiceBarMenuTests'`
Expected: PASS

### Task 3: Fix rebuild signing in both repos

**Files:**
- Modify: `flow-bar/build-app.sh`
- Modify: `brain-bar/build-app.sh`

**Step 1: Update build scripts**

- Use explicit deep signing with the configured Apple Development identity.
- Add post-build verification so the script fails if the installed app is ad-hoc signed.

**Step 2: Verify by rebuilding**

Run: `bash flow-bar/build-app.sh`
Run: `bash brain-bar/build-app.sh`
Expected: Both builds succeed and `codesign -dv --verbose=4` shows the Apple Development authority instead of `Signature=adhoc`.

### Task 4: Full verification and PR prep

**Files:**
- Verify only

**Step 1: Run repo verification**

Run: `swift test --package-path flow-bar`
Run: `bash flow-bar/build-app.sh`
Run: `bash brain-bar/build-app.sh`

**Step 2: Commit and PR**

- Commit VoiceBar changes in `voicelayer`.
- Commit build-script changes in `brainlayer`.
- Push `codex/rebuild-and-fix` in each repo and open PRs with rebuild/signing findings and test evidence.
