# Paste-Once and Atomic Clipboard Restore Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Prevent release/active-gesture repastes and restore the user's clipboard synchronously after fallback Cmd+V returns.

**Architecture:** Keep VoiceBar's complete-transcript AX-first, clipboard-plus-Cmd+V-second pipeline intact. Make the hotkey classifier distinguish explicit idle Shift+F5 repaste from active recording gestures, and replace only the delayed restore scheduling with the existing guarded restore call.

**Tech Stack:** Swift 5.9, AppKit/CoreGraphics, Swift Package Manager, XCTest, Bun.

---

### Task 1: Establish the RED hotkey guard

**Files:**
- Test: `flow-bar/Tests/VoiceBarTests/HotkeyManagerTests.swift:187-270`
- Modify: `flow-bar/Sources/VoiceBar/HotkeyManager.swift:368-464`

**Step 1: Verify the failing tests already present in the inherited WIP**

Run:

```bash
cd flow-bar && swift test --filter HotkeyManagerTests
```

Expected: the idle Shift+F5 release and active-hold Shift+F5 key-down assertions fail against the current classifier.

**Step 2: Implement the minimal classifier guard**

Move exact Shift-only classification ahead of the generic key-up return. Use these outcomes:

```swift
if exactShiftOnly {
    if type == .keyUp {
        return gestureIsActive ? .keyUp : .ignore
    }
    guard type == .keyDown else { return .ignore }
    guard autorepeat == 0 else { return gestureIsActive ? .consume : .ignore }
    guard !gestureIsActive else { return .consume }
    return .pasteLastTranscript
}
```

Keep all non-Shift hotkey behavior unchanged.

**Step 3: Verify GREEN**

Run the same filtered Swift test command. Expected: all `HotkeyManagerTests` pass.

### Task 2: Establish atomic clipboard restoration

**Files:**
- Test: `flow-bar/Tests/VoiceBarUITests/VoiceStatePasteTests.swift:1270-1387`
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceState.swift:343-350`
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceState.swift:1673-1778`

**Step 1: Verify the failing test already present in the inherited WIP**

Run:

```bash
cd flow-bar && swift test --filter VoiceStatePasteTests/testAutoPasteRestoresClipboardImmediatelyAfterFallbackPasteReturns
```

Expected: the test fails because a third delayed restore block is scheduled and the pasteboard still contains the transcript after the synthetic paste block returns.

**Step 2: Implement synchronous guarded restoration**

Replace the delayed restore scheduling immediately after `simulatedPasteHandler()` with:

```swift
restoreClipboardIfNeeded(
    from: pasteboardSnapshot,
    expectedChangeCount: changeCountAfterWrite
)
```

Delete only `pasteboardRestoreDelay` and `scheduleClipboardRestoreIfNeeded`. Retain `restoreClipboardIfNeeded` and its change-count guard verbatim.

**Step 3: Verify GREEN and clipboard-race preservation**

Run:

```bash
cd flow-bar && swift test --filter VoiceStatePasteTests
```

Expected: all paste tests pass, including the case where user clipboard content changes during the synthetic paste.

### Task 3: Verify mechanism preservation and regressions

**Files:**
- Inspect: `flow-bar/Sources/VoiceBarUI/VoiceState.swift`
- Inspect: `flow-bar/Sources/VoiceBar/CommandModeAXHelper.swift`

**Step 1: Inspect the production diff**

Run:

```bash
git diff b5de177 -- flow-bar/Sources/VoiceBarUI/VoiceState.swift flow-bar/Sources/VoiceBar/HotkeyManager.swift flow-bar/Sources/VoiceBar/CommandModeAXHelper.swift
```

Expected: only Shift+F5 classification and restore timing differ; `CommandModeAXHelper.swift` is unchanged, transcripts are not chunked, AX remains first, and Cmd+V remains the fallback.

**Step 2: Run the Swift suites**

Run:

```bash
cd flow-bar && swift test
```

Expected: zero failures.

**Step 3: Run the required TypeScript regression suite**

Run:

```bash
bun test src/
```

Expected: zero failures.

### Task 4: Review, publish, and hand off without merging

**Files:**
- Review all changed tracked files from `git status --short`

**Step 1: Run bounded local CodeRabbit review**

Run `coderabbit review --agent` with an approximately three-minute timeout. Fix actionable CRITICAL/HIGH/MED findings test-first; record rate limits or timeouts explicitly.

**Step 2: Commit and push**

Stage only task files, commit intentionally, and push `fix/paste-once-atomic-restore`.

**Step 3: Create a ready-for-review PR**

The PR body must state that this VoiceLayer PR fixes no-release-repaste plus atomic restore while preserving the mechanism, and that long-paste pane survival still depends on the paired cmux-side fix. Include before/after behavior and exact test evidence. Do not claim the forbidden resident-app/live-pane acceptance was run.

**Step 4: Invoke and read reviews**

Request `@coderabbitai review`, `@codex review`, and `@cursor @bugbot review`. Read all returned feedback and address HIGH/MED findings test-first, then re-run verification and push fixes.

**Step 5: Stop at the worker endpoint**

Do not merge. Report the verified PR URL and review state to `voicelayerClaude` in `collab/voicelayer-self-living/` and store the implementation decision and milestone in BrainLayer.
