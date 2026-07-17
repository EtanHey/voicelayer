# Paste-Once and Atomic Clipboard Restore Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Prevent release/active-gesture repastes and restore the user's clipboard after the existing bounded fallback delay.

**Architecture:** Keep VoiceBar's complete-transcript AX-first, clipboard-plus-Cmd+V-second pipeline intact. Make the hotkey classifier distinguish explicit idle Shift+F5 repaste from active recording gestures, and retain the existing delayed, change-count-guarded clipboard restoration. The VoiceLayer lead selected this bounded-delay behavior on 2026-07-17 because immediate restoration races asynchronous target consumption.

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
        return gestureIsActive ? .keyUp : .consume
    }
    guard type == .keyDown else { return .ignore }
    guard autorepeat == 0 else { return gestureIsActive ? .consume : .ignore }
    guard !gestureIsActive else { return .consume }
    return .pasteLastTranscript
}
```

Keep all non-Shift hotkey behavior unchanged.

Track the keycode when key-down returns `.pasteLastTranscript`, and consume its matching key-up before flag-based classification. Clear stale pairing state on the next non-autorepeat target key-down. This preserves event pairing when Shift is released before F5.

**Step 3: Verify GREEN**

Run the same filtered Swift test command. Expected: all `HotkeyManagerTests` pass, including Shift-up-before-F5-up ordering.

### Task 2: Preserve bounded, guarded clipboard restoration

**Files:**
- Test: `flow-bar/Tests/VoiceBarUITests/VoiceStatePasteTests.swift:1270-1387`
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceState.swift:343-350`
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceState.swift:1673-1778`

**Step 1: Restore the bounded-delay test and verify RED against the inherited immediate implementation**

Run:

```bash
cd flow-bar && swift test --filter VoiceStatePasteTests/testAutoPasteRestoresClipboardAfterFallbackPasteDelay
```

Expected: the test fails while the branch still restores immediately instead of scheduling the production delay.

**Step 2: Restore bounded guarded restoration**

After `simulatedPasteHandler()`, retain:

```swift
scheduleClipboardRestoreIfNeeded(
    from: pasteboardSnapshot,
    expectedChangeCount: changeCountAfterWrite
)
```

Retain `pasteboardRestoreDelay = 0.5`, `scheduleClipboardRestoreIfNeeded`, `restoreClipboardIfNeeded`, and the change-count guard.

**Step 3: Verify GREEN and clipboard-race preservation**

Run:

```bash
cd flow-bar && swift test --filter VoiceStatePasteTests
```

Expected: all paste tests pass, including delayed restoration and the case where user clipboard content changes before the restore callback.

### Task 3: Verify mechanism preservation and regressions

**Files:**
- Inspect: `flow-bar/Sources/VoiceBarUI/VoiceState.swift`
- Inspect: `flow-bar/Sources/VoiceBar/CommandModeAXHelper.swift`

**Step 1: Inspect the production diff**

Run:

```bash
git diff b5de177 -- flow-bar/Sources/VoiceBarUI/VoiceState.swift flow-bar/Sources/VoiceBar/HotkeyManager.swift flow-bar/Sources/VoiceBar/CommandModeAXHelper.swift
```

Expected: only Shift+F5 classification differs from current main; restore timing and `CommandModeAXHelper.swift` are unchanged, transcripts are not chunked, AX remains first, and Cmd+V remains the fallback.

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
