# Notch W1 Teleprompter Read-Back and HOLD-RECORDING Implementation Plan

> **Execution:** Follow this plan task-by-task with explicit RED/GREEN evidence and no mid-lane approval pause.

**Goal:** Retain a completed VoiceBar teleprompter for scrollable read-back and add a VAD-only HOLD-RECORDING control that suppresses silence auto-close while engaged.

**Architecture:** `VoiceState` keeps a separate, in-memory post-playback snapshot while remaining truthfully idle; presentation/layout code renders that snapshot in the existing teleprompter envelope and blocks idle collapse. A mirrored `set_recording_hold` command controls a secure cross-process flag consumed by a pure silence-policy state machine inside the existing VAD loop.

**Tech Stack:** Swift 5.9, SwiftUI/Observation, XCTest, TypeScript, Bun test, NDJSON Unix-socket protocol.

---

### Task 1: Retain completed teleprompter state

**Files:**
- Modify: `flow-bar/Tests/VoiceBarUITests/VoiceStateTests.swift`
- Modify: `flow-bar/Tests/VoiceBarUITests/VoiceBarDevStateTests.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceState.swift`

**Step 1: Write failing lifecycle tests**

Add tests that send speaking text, subtitle boundaries, and playback idle, then assert:

```swift
XCTAssertEqual(state.mode, .idle)
XCTAssertEqual(state.teleprompterText, "Original Etan spelling")
XCTAssertEqual(state.teleprompterWordBoundaries.map(\.text), ["Eh tahn", "spelling"])
XCTAssertTrue(state.isTeleprompterReadback)
```

Add independent tests proving temporary hide/show survives playback idle, explicit retained dismissal clears the snapshot, generic idle does not overwrite it, and new recording/speaking state clears it.

Add an async collapse test that uses a 10 ms delay and proves retained read-back stays expanded while ordinary idle still collapses.

**Step 2: Run tests to verify RED**

Run:

```bash
cd flow-bar
swift test --filter 'VoiceStateTests|VoiceBarDevStateTests'
```

Expected: compile failures for missing retained teleprompter API.

**Step 3: Implement the minimal snapshot lifecycle**

Add private retained text/boundaries and public computed presentation accessors. Capture only when the previous mode is speaking, idle source is playback, and original text is non-empty. Preserve the temporary visibility flag at playback idle; clear the snapshot on explicit dismissal and new recording/speaking turns.

Gate `startCollapseTimer()` when retained content exists and restart ordinary collapse after permanent dismissal.

**Step 4: Run tests to verify GREEN**

Run the same focused command. Expected: all selected tests pass with 0 failures.

### Task 2: Render a static, scrollable idle read-back

**Files:**
- Modify: `flow-bar/Tests/VoiceBarUITests/TeleprompterContentModelTests.swift`
- Modify: `flow-bar/Tests/VoiceBarUITests/VoiceBarPanelLayoutTests.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/TeleprompterView.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceBarPanelLayout.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/BarView.swift`
- Modify: `flow-bar/Sources/VoiceBar/VoiceBarApp.swift`

**Step 1: Write failing policy/layout tests**

Add pure tests for a read-back presentation policy:

```swift
XCTAssertFalse(TeleprompterPlaybackPolicy.animatesTimeline(isReadback: true))
XCTAssertEqual(TeleprompterPlaybackPolicy.wordOpacity(isReadback: true), 0.9)
XCTAssertTrue(TeleprompterPlaybackPolicy.showsScrollIndicators(isReadback: true))
```

Add a layout test calling `VoiceBarPanelLayout.make(mode: .idle, ..., showsTeleprompter: true)` and assert the full panel width and teleprompter height.

**Step 2: Run tests to verify RED**

Run:

```bash
cd flow-bar
swift test --filter 'TeleprompterContentModelTests|VoiceBarPanelLayoutTests'
```

Expected: compile failures for the missing policy and layout parameter.

**Step 3: Implement read-back presentation**

Add `isReadback` to `TeleprompterView`; stop/restart animation on phase changes, render uniform readable opacity in read-back, and expose scroll indicators. Refactor `BarView.stateContent` so live and retained content share one teleprompter branch, with waveform only during live speaking.

Pass a `showsTeleprompter` flag through `VoiceBarApp.panelLayout`, `VoiceBarPanelLayout`, and BarView sizing. Add eye hide/show and × permanent-dismiss controls for idle read-back while retaining replay.

**Step 4: Run tests to verify GREEN**

Run the same focused command. Expected: all selected tests pass with 0 failures.

### Task 3: Define HOLD protocol and silence policy

**Files:**
- Create: `src/recording-hold.ts`
- Create: `src/__tests__/recording-hold.test.ts`
- Modify: `src/__tests__/socket-protocol.test.ts`
- Modify: `src/socket-protocol.ts`
- Modify: `src/paths.ts`
- Modify: `flow-bar/Sources/VoiceBar/SocketProtocol.swift`

**Step 1: Write failing TypeScript tests**

Add strict protocol cases:

```ts
expect(parseCommand('{"cmd":"set_recording_hold","engaged":true,"id":"hold-1"}'))
  .toEqual({ cmd: "set_recording_hold", engaged: true, id: "hold-1" });
expect(parseCommand('{"cmd":"set_recording_hold"}')).toBeNull();
```

Add pure policy tests proving:

- normal post-speech silence closes at the configured threshold;
- held post-speech silence never closes and resets accumulated silence;
- release requires a fresh full threshold;
- held pre-speech silence never times out and release requires a fresh pre-speech window.

Add flag lifecycle tests using an explicit temporary test path.

**Step 2: Run tests to verify RED**

Run:

```bash
bun test src/__tests__/recording-hold.test.ts src/__tests__/socket-protocol.test.ts
```

Expected: missing module/API failures and protocol parse mismatch.

**Step 3: Implement protocol, secure flag, and pure gate**

Add `recordingHoldFilePath()` under `STATE_DIR`, with a test override. Implement set/read/clear helpers using safe writes. Implement a `RecordingSilenceAutoClosePolicy` that owns has-speech, post-speech silence, and pre-speech unheld counters.

Extend `AckCommand`, `SocketCommand`, and `parseCommand` with strict Boolean validation. Add the same command name and payload shape to Swift `SocketProtocol.swift`.

**Step 4: Run tests to verify GREEN**

Run the same Bun command. Expected: all selected tests pass with 0 failures.

### Task 4: Wire HOLD into daemon recording

**Files:**
- Modify: `src/__tests__/socket-handlers-idempotency.test.ts`
- Modify: `src/socket-handlers.ts`
- Modify: `src/input.ts`

**Step 1: Write failing handler tests**

Spy on the hold writer. Assert recording accepts engage/release and idle/transcribing return no-op without writing.

```ts
expect(handleSocketCommand({ cmd: "set_recording_hold", engaged: true, id: "h1" }))
  .toEqual({ type: "ack", command: "set_recording_hold", outcome: "accept", id: "h1" });
```

**Step 2: Run tests to verify RED**

Run:

```bash
bun test src/__tests__/socket-handlers-idempotency.test.ts
```

Expected: handler has no matching command case.

**Step 3: Implement minimal daemon wiring**

Handle the new command only while recording. Clear stale hold at capture start and in `recordToBuffer.finish()`. Replace inline silence counters with the tested policy; consult the hold flag on each VAD chunk. Preserve explicit stop/cancel and the overall timer unchanged.

**Step 4: Run tests to verify GREEN**

Run handler and recording-hold tests together. Expected: all selected tests pass with 0 failures.

### Task 5: Add VoiceBar HOLD state and control

**Files:**
- Modify: `flow-bar/Tests/VoiceBarUITests/VoiceStateTests.swift`
- Modify: `flow-bar/Tests/VoiceBarUITests/VoiceBarPresentationTests.swift`
- Modify: `flow-bar/Tests/VoiceBarUITests/BarViewClickabilityTests.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceBarContract.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceBarPresentation.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceState.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/BarView.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/Theme.swift`

**Step 1: Write failing state/presentation tests**

Assert VAD recording can optimistically send engage/release commands with IDs, PTT cannot engage, reject ack rolls back, and recording exit clears state. Add pure presentation assertions for VAD-only visibility, icon, label, hint, and selected state. Add a click test that locates the hold button and observes the command payload.

**Step 2: Run tests to verify RED**

Run:

```bash
cd flow-bar
swift test --filter 'VoiceStateTests|VoiceBarPresentationTests|BarViewClickabilityTests'
```

Expected: missing HOLD state/presentation APIs.

**Step 3: Implement the control**

Add `IntentCommand.setRecordingHold`, optimistic target tracking, ack rollback, and recording-exit reset. Add a selected pill-button style and explicit accessibility label/hint/help. Increase the recording pill width only enough for the third VAD control; PTT keeps the existing two-control width.

**Step 4: Run tests to verify GREEN**

Run the same Swift command. Expected: all selected tests pass with 0 failures.

### Task 6: Update the OpenSpec test-drive scaffold

**Files:**
- Create in worktree from the throwaway scaffold: `openspec/changes/notch-app/proposal.md`
- Create in worktree from the throwaway scaffold: `openspec/changes/notch-app/tasks.md`
- Create in worktree from the throwaway scaffold: `openspec/changes/notch-app/specs/voicebar-notch/spec.md`

**Step 1: Update only the two W1 requirement clusters**

Expand the teleprompter requirement with retained lifetime, reversible hide/show, permanent dismissal, new-turn clearing, static read-back, and original-script display. Expand HOLD with VAD-only visibility, accessibility copy, pre/post-speech suppression, fresh countdown on release, and unchanged explicit stop/cancel/overall timeout.

Mark tasks 2.1 and 2.2 complete only after verification. Do not run or hunt for an analyzer executable; note its local absence in the report.

**Step 2: Verify scaffold wording**

Run `rg -n 'Teleprompter persistence|Hold-recording|fresh|original|analyzer' openspec/changes/notch-app` and read all three files.

### Task 7: Full verification, review, PR, and report

**Files:**
- Create: `.verified/` artifact via verification script (gitignored)
- Create: `/Users/etanheyman/Gits/orchestrator/docs.local/handoffs/2026-07-17-notch-w1-REPORT.md`

**Step 1: Run full automated verification**

```bash
bun test
(cd flow-bar && swift test)
bash scripts/voicelayer-verify.sh --corpus 10
```

Read complete output and record exact pass/fail/skip counts.

**Step 2: Build and launch only an isolated app**

```bash
bash flow-bar/build-app.sh \
  --install-path /tmp/VoiceBar-dev-notch-w1.app \
  --no-stop --no-relaunch
```

Launch the isolated executable with isolated VoiceBar and MCP socket paths plus isolated recording-state/hold paths. Drive live speaking→idle read-back, scroll/hide/show/dismiss, and VAD recording HOLD engage/release. Capture screenshots and inspect every artifact. Clean only the exact isolated app/process/path targets afterward; never use `pkill`.

**Step 3: Run bounded local review and commit**

Run `coderabbit review --agent` with the documented bounded timeout. If rate-limited, record it and continue on fresh test evidence. Review `git diff`, `git diff --check`, and `git status`; commit specific files.

**Step 4: Push and open a ready PR against main**

Include L1 §10 clusters 1/4a, §8.11/§8.12, two-channel law, exact tests, corpus artifact, isolated visual receipt, and local CodeRabbit/OpenSpec limitations. Do not merge.

**Step 5: Invoke and read reviewers**

Request `@codex review` and `@cursor @bugbot review` immediately. Read all available checks/comments, fix actionable critical/major findings with TDD, push, and request re-review. Stop at the worker endpoint because the brief assigns merge to the lane owner.

**Step 6: Write and verify the absolute-path report**

Include the verified PR URL, exact test counts, visual receipt description/path, corpus artifact, OpenSpec updates, and the explicit statement that no analyzer executable exists locally and none was sought. Final line exactly:

```text
NOTCH_W1_DONE
```

Read the full report before completion and store WHAT + WHY in BrainLayer.
