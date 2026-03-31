# Phase 6 Daemon Hotkey Foundation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship a reliable always-available VoiceBar foundation with a single-process daemon, login-safe activation, durable hotkey entry points, and wake/sleep recovery.

**Architecture:** VoiceBar remains the persistent macOS agent and becomes responsible for daemon lifecycle orchestration instead of spawning an unmanaged child blindly. The app will use a three-tier activation path: connect to an already-live daemon, launch one if absent, and expose a fresh-session liveness surface that works before any manual interaction. Hotkey handling will support the in-app global listener plus URL-based external activation, while wake recovery will reinitialize audio-dependent pieces after system sleep with a guarded wake delay.

**Tech Stack:** Swift 5.9, SwiftUI/AppKit, Bun daemon in `src/daemon.ts`, XCTest, macOS login-item/build packaging.

---

### Task 1: Daemon activation and liveness model

**Files:**
- Create: `flow-bar/Sources/VoiceBar/VoiceBarDaemonController.swift`
- Modify: `flow-bar/Sources/VoiceBar/VoiceBarApp.swift`
- Modify: `flow-bar/Sources/VoiceBar/VoiceLayerPaths.swift`
- Test: `flow-bar/Tests/VoiceBarTests/VoiceBarDaemonControllerTests.swift`

**Step 1: Write the failing tests**

Add tests for:
- returning `.alreadyRunning` when daemon liveness probe succeeds
- returning `.launched` when probe fails but process launch succeeds
- returning `.unavailable` when no launch configuration exists
- exposing a deterministic liveness probe command/path for fresh-session verification

**Step 2: Run test to verify it fails**

Run: `swift test --package-path flow-bar --filter VoiceBarDaemonControllerTests`
Expected: FAIL because controller types and liveness behavior do not exist.

**Step 3: Write minimal implementation**

Implement a daemon controller that:
- checks for an existing live daemon before launching
- resolves repo vs bundled daemon launch configuration
- launches only when needed
- surfaces current activation result for UI/logging/tests

**Step 4: Run test to verify it passes**

Run: `swift test --package-path flow-bar --filter VoiceBarDaemonControllerTests`
Expected: PASS

### Task 2: App lifecycle wiring for single-process ownership

**Files:**
- Modify: `flow-bar/Sources/VoiceBar/VoiceBarApp.swift`
- Modify: `flow-bar/Sources/VoiceBar/SocketServer.swift`
- Test: `flow-bar/Tests/VoiceBarTests/VoiceBarAppLifecycleTests.swift`

**Step 1: Write the failing tests**

Add tests for:
- app launch triggering daemon activation once
- app termination stopping only the owned daemon process
- duplicate VoiceBar launches exiting without relaunching the daemon

**Step 2: Run test to verify it fails**

Run: `swift test --package-path flow-bar --filter VoiceBarAppLifecycleTests`
Expected: FAIL because lifecycle hooks are not injectable/testable.

**Step 3: Write minimal implementation**

Refactor the app delegate to inject daemon lifecycle collaborators and to keep ownership state separate from “daemon already running” state.

**Step 4: Run test to verify it passes**

Run: `swift test --package-path flow-bar --filter VoiceBarAppLifecycleTests`
Expected: PASS

### Task 3: Hotkey foundation and activation policy

**Files:**
- Modify: `flow-bar/Sources/VoiceBar/HotkeyManager.swift`
- Modify: `flow-bar/Sources/VoiceBar/VoiceBarApp.swift`
- Modify: `flow-bar/Sources/VoiceBar/VoiceBarPresentation.swift`
- Test: `flow-bar/Tests/VoiceBarTests/HotkeyManagerTests.swift`
- Test: `flow-bar/Tests/VoiceBarTests/VoiceBarPresentationTests.swift`

**Step 1: Write the failing tests**

Add tests for:
- hold and double-tap semantics on the supported hotkey path
- explicit handling for URL-triggered `start-recording`, `stop-recording`, and `toggle`
- permission messaging distinguishing in-app global hotkey from external fallback activation

**Step 2: Run test to verify it fails**

Run: `swift test --package-path flow-bar --filter HotkeyManagerTests`
Run: `swift test --package-path flow-bar --filter VoiceBarPresentationTests`
Expected: FAIL for new semantics/messages.

**Step 3: Write minimal implementation**

Adjust the hotkey layer and app command handling so the supported path is clear:
- internal global hotkey remains hold/double-tap capable
- URL entry points remain available for Karabiner or other external fallback
- Fn/Globe is never treated as a supported direct key target

**Step 4: Run test to verify it passes**

Run: `swift test --package-path flow-bar --filter HotkeyManagerTests`
Run: `swift test --package-path flow-bar --filter VoiceBarPresentationTests`
Expected: PASS

### Task 4: Wake and sleep recovery

**Files:**
- Create: `flow-bar/Sources/VoiceBar/WakeRecoveryCoordinator.swift`
- Modify: `flow-bar/Sources/VoiceBar/VoiceBarApp.swift`
- Modify: `flow-bar/Sources/VoiceBar/AudioLevelMonitor.swift`
- Test: `flow-bar/Tests/VoiceBarTests/WakeRecoveryCoordinatorTests.swift`

**Step 1: Write the failing tests**

Add tests for:
- observing wake notifications
- delaying restart work by 500ms after wake
- restarting audio-dependent components only when required
- resetting hotkey transient state during sleep/wake transitions

**Step 2: Run test to verify it fails**

Run: `swift test --package-path flow-bar --filter WakeRecoveryCoordinatorTests`
Expected: FAIL because wake recovery does not exist.

**Step 3: Write minimal implementation**

Implement a coordinator that:
- subscribes to sleep/wake notifications
- schedules recovery work 500ms after wake
- restarts AVAudioEngine-backed components safely
- avoids duplicate restart loops

**Step 4: Run test to verify it passes**

Run: `swift test --package-path flow-bar --filter WakeRecoveryCoordinatorTests`
Expected: PASS

### Task 5: Login/build packaging and final verification

**Files:**
- Modify: `flow-bar/build-app.sh`
- Modify: `flow-bar/bundle/Info.plist`
- Modify: `flow-bar/Sources/VoiceBar/VoiceBarApp.swift`
- Test: `flow-bar/Tests/VoiceBarTests/VoiceBarDaemonControllerTests.swift`

**Step 1: Write the failing tests**

Add tests for any build-time or runtime config surface that can be exercised from Swift, especially fresh-session liveness command/path exposure.

**Step 2: Run test to verify it fails**

Run: `swift test --package-path flow-bar --filter VoiceBarDaemonControllerTests`
Expected: FAIL until packaging-visible configuration matches implementation.

**Step 3: Write minimal implementation**

Update bundle/build assets so the packaged app includes the daemon resources and login/lifecycle messaging matches the shipped behavior.

**Step 4: Run test to verify it passes**

Run: `swift test --package-path flow-bar --filter VoiceBarDaemonControllerTests`
Expected: PASS

### Final verification

Run:
- `swift test --package-path flow-bar`
- `bash flow-bar/build-app.sh`

Expected:
- all Swift tests pass
- VoiceBar app bundle builds successfully with the daemon resources included
