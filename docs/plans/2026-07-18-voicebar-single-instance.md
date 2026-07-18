# VoiceBar Canonical Single-Instance Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make every normal VoiceBar launch converge on one exact process while preserving isolated QA apps.

**Architecture:** Add a pure launch planner keyed by exact PID and resolved bundle path, then invoke it from `AppDelegate` before socket startup. `/Applications/VoiceBar.app` has precedence; otherwise the new normal-stack launch supersedes older normal-stack instances.

**Tech Stack:** Swift 5.9, AppKit `NSRunningApplication`, XCTest.

---

### Task 1: RED launch-planning contract

**Files:**
- Create: `flow-bar/Tests/VoiceBarTests/VoiceBarInstanceGuardTests.swift`

1. Add failing tests for canonical-new superseding noncanonical PIDs, canonical-old defeating a noncanonical new launch, noncanonical-new superseding older noncanonical PIDs, and isolated bypass.
2. Run `swift test --filter VoiceBarInstanceGuardTests` from `flow-bar/` and confirm the missing planner fails compilation.

### Task 2: Minimal planner and runtime wiring

**Files:**
- Create: `flow-bar/Sources/VoiceBar/VoiceBarInstanceGuard.swift`
- Modify: `flow-bar/Sources/VoiceBar/VoiceBarApp.swift`

1. Implement the pure planner with `bypass`, `exitCurrent`, and `supersede([pid_t])` decisions.
2. Resolve bundle paths before comparison and keep PID lists unique and sorted.
3. Replace the exit-new singleton block in `AppDelegate` with the plan.
4. Terminate only matching `NSRunningApplication` objects for planned exact PIDs; wait briefly and force-terminate only a still-live planned app.
5. Keep `VoiceLayerPaths.enforcesSingletonInstance == false` as a full bypass.

### Task 3: GREEN and regression verification

**Files:**
- Modify only if a failing assertion exposes a contract gap.

1. Run `swift test --filter VoiceBarInstanceGuardTests` and confirm green.
2. Run full `swift test`, `bun test`, `bun run typecheck`, and `git diff --check`.
3. Build the isolated app and prove it coexists with the resident because its unique socket override bypasses the guard; terminate its exact PID immediately after capture.
