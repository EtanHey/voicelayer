# VoiceBar Dev-Expanded State Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add an opt-in VoiceBar development state that suppresses idle dot-collapse while preserving the default pill and F5 behavior.

**Architecture:** A pure `VoiceBarDevState` policy resolves an environment variable or `/tmp` sentinel at launch. `VoiceState` receives the resolved Boolean and gates only its existing idle-collapse scheduler, leaving views, panel geometry, hotkeys, protocol, and daemon code untouched.

**Tech Stack:** Swift 5.9, Swift Package Manager, XCTest, SwiftUI/Observation.

---

### Task 1: Resolve the opt-in development flag

**Files:**
- Create: `flow-bar/Sources/VoiceBarUI/VoiceBarDevState.swift`
- Create: `flow-bar/Tests/VoiceBarUITests/VoiceBarDevStateTests.swift`

**Step 1: Write the failing policy tests**

Add tests proving:

```swift
XCTAssertFalse(VoiceBarDevState.shouldKeepExpanded(environment: [:], fileExists: { _ in false }))
XCTAssertTrue(VoiceBarDevState.shouldKeepExpanded(
    environment: [VoiceBarDevState.keepExpandedEnvironmentVariable: " 1 "],
    fileExists: { _ in false }
))
XCTAssertTrue(VoiceBarDevState.shouldKeepExpanded(
    environment: [:],
    fileExists: { $0 == VoiceBarDevState.keepExpandedFlagPath }
))
```

**Step 2: Run the test to verify RED**

Run: `swift test --filter VoiceBarDevStateTests`

Expected: compilation fails because `VoiceBarDevState` does not exist.

**Step 3: Implement the policy**

Create a public enum with the environment key, exact `/tmp` flag path, and injected environment/file-existence parameters. Trim whitespace and accept only the exact value `1`.

**Step 4: Run the test to verify GREEN**

Run: `swift test --filter VoiceBarDevStateTests`

Expected: 3 tests pass, 0 fail.

### Task 2: Gate the existing idle-collapse scheduler

**Files:**
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceState.swift`
- Modify: `flow-bar/Tests/VoiceBarUITests/VoiceBarDevStateTests.swift`

**Step 1: Write failing state-behavior tests**

Add async tests that create `VoiceState(keepsExpandedInDevState: true/false)`, set a 10 ms collapse delay, enter idle with `setHovering(false)`, wait 30 ms, and assert:

- enabled stays `isCollapsed == false`
- disabled becomes `isCollapsed == true`

**Step 2: Run the test to verify RED**

Run: `swift test --filter VoiceBarDevStateTests`

Expected: compilation fails because the injected initializer parameter does not exist.

**Step 3: Implement the scheduler gate**

Add a private immutable `keepsExpandedInDevState` property and an initializer parameter defaulting to `VoiceBarDevState.shouldKeepExpanded()`. At the start of `startCollapseTimer()`, cancel the prior timer; if enabled, force `isCollapsed = false` and return. Otherwise schedule the existing timer unchanged.

**Step 4: Run the targeted test to verify GREEN**

Run: `swift test --filter VoiceBarDevStateTests`

Expected: 5 tests pass, 0 fail.

**Step 5: Run collapse regression coverage**

Run: `swift test --filter VoiceStatePasteTests.testModalInteractionSuppressesIdleCollapseAndRestoresExpandedState`

Expected: 1 test passes, 0 fail.

### Task 3: Verify and publish the separate PR

**Files:**
- Verify only; no extra production surface.

**Step 1: Run package verification**

Run: `swift test`

Expected: all non-artifact tests pass; artifact/runtime-only tests may retain their documented skips.

**Step 2: Build the release app without replacing the installed app**

Run: `bash flow-bar/build-app.sh --install-path /tmp/VoiceBar-dev-expanded.app --no-stop --no-relaunch`

Expected: release build and signing complete with exit 0.

**Step 3: Audit frozen surfaces**

Run focused diffs confirming no changes under `flow-bar/Sources/VoiceBar/`, `flow-bar/Sources/VoiceBarUI/BarView.swift`, hotkey/F5 files, `src/`, or `scripts/`.

**Step 4: Perform real visual/runtime verification**

Launch the isolated app executable with `VOICEBAR_DEV_KEEP_EXPANDED=1` and an isolated `QA_VOICE_SOCKET_PATH`, wait longer than the collapse delay, then use computer-use or a screenshot-capable tool to verify the rendered idle pill remains expanded. Remove the isolated process/app afterward.

**Step 5: Review, commit, push, and open a ready PR**

Run the bounded CodeRabbit pre-commit review, address valid findings, commit specific files, push `feat/voicebar-dev-expanded`, and open a separate ready-for-review PR against `main`. The PR body must state the flags, unchanged default, frozen-surface audit, L1 §2 and L1 §10 / §8.11 context, tests/build evidence, and visual verification receipt.

**Step 6: Invoke reviewers and stop without merging**

Request `@codex review` and `@cursor @bugbot review`, read available review/check results, address actionable critical/major findings, and report the PR URL. Do not merge.
