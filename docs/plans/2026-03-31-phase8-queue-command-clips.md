# Phase 8 Queue Command Clips Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Land interruptible queued TTS, AX-first Command Mode with clipboard fallback, and clip-marker event emission in VoiceBar.

**Architecture:** Extend the existing playback queue and socket protocol in Bun, then add native Swift state/helpers for command execution and clip marker UI. Bun remains the transport/orchestration layer; Swift owns AX reads/writes, write verification, and clipboard fallback.

**Tech Stack:** Bun, TypeScript, SwiftUI, AppKit Accessibility APIs, existing VoiceBar socket transport.

---

### Task 1: Stabilize Worktree Baseline

**Files:**
- Modify only if needed: `package.json`, lockfile, or environment docs

**Step 1: Normalize dependencies**

Run: `bun install`

**Step 2: Verify baseline**

Run: `bun test`
Expected: Either PASS or a reduced set of known baseline failures documented before Phase 8 edits.

**Step 3: Record baseline drift**

If pre-existing failures remain, note them in the working notes and do not attribute them to Phase 8.

### Task 2: Queue Semantics Red Tests

**Files:**
- Modify: `src/__tests__/tts-priority-queue.test.ts`
- Modify or Create: `src/__tests__/audio-queue-visualization.test.ts`
- Modify or Create: `src/__tests__/socket-stop-queue.test.ts`

**Step 1: Write the failing tests**

Add tests for:
- command-priority items barging into lower-priority playback
- debounce-and-collapse behavior for repeated command chatter
- queue snapshots that expose interruption state clearly
- stop/cancel behavior leaving no stale queue state

**Step 2: Run test to verify it fails**

Run: `bun test src/__tests__/tts-priority-queue.test.ts src/__tests__/audio-queue-visualization.test.ts src/__tests__/socket-stop-queue.test.ts`

**Step 3: Write minimal implementation**

Extend `src/tts.ts` queue metadata and interruption behavior only enough to satisfy the tests.

**Step 4: Run test to verify it passes**

Run the same targeted command and confirm green.

### Task 3: Command Mode Protocol Red Tests

**Files:**
- Modify: `src/__tests__/socket-protocol.test.ts`
- Modify or Create: `src/__tests__/socket-handlers.test.ts`

**Step 1: Write the failing tests**

Add protocol coverage for:
- command-mode request/response payloads
- selection transform requests
- clip-marker event serialization
- invalid command payload rejection

**Step 2: Run test to verify it fails**

Run: `bun test src/__tests__/socket-protocol.test.ts src/__tests__/socket-stop-queue.test.ts`

**Step 3: Write minimal implementation**

Update `src/socket-protocol.ts` and `src/socket-handlers.ts` with the new command and event shapes.

**Step 4: Run test to verify it passes**

Run the same targeted command and confirm green.

### Task 4: Swift Command Mode And Clip State Red Tests

**Files:**
- Modify or Create: `flow-bar/Tests/VoiceBarTests/VoiceStateCommandModeTests.swift`
- Modify or Create: `flow-bar/Tests/VoiceBarTests/VoiceBarPresentationTests.swift`

**Step 1: Write the failing tests**

Add tests for:
- VoiceState handling command-mode and clip-marker events
- visible pill/panel text for command mode
- queue/clip indicator summarization

**Step 2: Run test to verify it fails**

Run: `swift test --package-path flow-bar --filter VoiceStateCommandModeTests`

**Step 3: Write minimal implementation**

Update `VoiceState.swift`, `BarView.swift`, and `VoiceBarPresentation.swift` to satisfy the new state/UI contract.

**Step 4: Run test to verify it passes**

Run the same filtered Swift command and confirm green.

### Task 5: Native AX And Clipboard Helper Red Tests

**Files:**
- Create: `flow-bar/Sources/VoiceBar/CommandModeAXHelper.swift`
- Create: `flow-bar/Tests/VoiceBarTests/CommandModeAXHelperTests.swift`

**Step 1: Write the failing tests**

Add tests for:
- AX-first selection read
- AX write verification via readback
- clipboard fallback when AX fails or verification mismatches

**Step 2: Run test to verify it fails**

Run: `swift test --package-path flow-bar --filter CommandModeAXHelperTests`

**Step 3: Write minimal implementation**

Implement a native helper seam with injectable read/write/pasteboard behavior.

**Step 4: Run test to verify it passes**

Run the same filtered Swift command and confirm green.

### Task 6: Clip Marker Emission And Integration

**Files:**
- Modify: `src/tts.ts`
- Modify: `src/socket-protocol.ts`
- Modify: `src/socket-handlers.ts`
- Modify: `flow-bar/Sources/VoiceBar/VoiceState.swift`

**Step 1: Write the failing integration tests**

Add tests that prove clip markers are emitted, parsed, and stored end-to-end.

**Step 2: Run test to verify it fails**

Run focused Bun and Swift tests for clip-marker flows.

**Step 3: Write minimal implementation**

Emit first-class marker events from Bun and persist/render them in Swift.

**Step 4: Run test to verify it passes**

Re-run the focused suites and confirm green.

### Task 7: Full Verification And PR

**Files:**
- Verify all changed files above

**Step 1: Run full verification**

Run:
- `bun test`
- `swift test --package-path flow-bar`

**Step 2: Pre-commit review**

Run: `cr review --plain`

**Step 3: Publish**

Run:

```bash
git push -u origin phase8/queue-command-clips
gh pr create --base main
gh pr comment <PR_NUM> --body "@coderabbitai review"
gh pr comment <PR_NUM> --body "@codex review"
gh pr comment <PR_NUM> --body "@cursor @bugbot review"
gh pr comment <PR_NUM> --body "@greptileai review"
```
