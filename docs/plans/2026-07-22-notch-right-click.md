# VoiceBar Notch Right-Click Restoration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Restore the VoiceBar context menu for secondary clicks on every rendered notch/wing pixel without reclaiming transparent panel margins from macOS.

**Architecture:** Separate tight rendered-surface event admission from mounted-control interaction geometry. The rendered path admits host/window/context-menu events; exact control rectangles remain the only drag/control targets.

**Tech Stack:** Swift 6, AppKit, SwiftUI, CoreGraphics, XCTest, Bun, shell release verification.

---

### Task 1: Add the right-click regression contract

**Files:**
- Modify: `flow-bar/Tests/VoiceBarUITests/BarViewClickabilityTests.swift`
- Modify: `flow-bar/Tests/VoiceBarTests/AppLifecycleTests.swift`

1. Add tests that configure a hosting view with separate control and rendered-surface providers.
2. Assert a mounted control and representative rendered body/wing points hit.
3. Assert transparent shadow/margin points return `nil`.
4. Assert panel context-menu eligibility uses the rendered surface while drag eligibility remains control-only.
5. Run `swift test --package-path flow-bar --filter 'BarViewClickabilityTests|AppLifecycleTests'` and confirm the new assertions fail for the missing seam.

### Task 2: Implement the minimal AppKit routing seam

**Files:**
- Modify: `flow-bar/Sources/VoiceBarUI/FloatingPanel.swift`
- Modify: `flow-bar/Sources/VoiceBar/VoiceBarApp.swift`

1. Add `renderedSurfaceHitTestProvider` to `PillHostingView` and use it in `hitTest`.
2. Add `contextMenuHitTestProvider` to `FloatingPillPanel`; keep `startsDrag` on `activeHitTestProvider`.
3. Wire both new providers to `currentPanelLayout().containsVisibleSurface`.
4. Make window-wide passthrough use `containsVisibleSurface` so only transparent margins ignore mouse events.
5. Re-run the filtered tests and confirm zero failures.
6. Run `git diff --check`.

### Task 3: Verify release acceptance and publish the worker PR

**Files:**
- Modify: `/Users/etanheyman/Gits/orchestrator/collab/2026-07-17-voicelayer-notch-w1-w2.md`
- Generate: `.verified/verified-runtime-fix-notch-363c-rightclick-<short-sha>.txt`

1. Run the full Swift and Bun suites and the notch event-handling corpus/harness.
2. Build a unique isolated app path and keep every QA window at or beyond `(-20000,-20000)`.
3. Exercise secondary clicks on rendered wing/body points in all states, including recording, and verify transparent margins remain pass-through.
4. Commit the implementation, then run exact-head corpus/runtime verification.
5. Produce and validate an exact-head Developer-ID/notarized build without touching `/Applications/VoiceBar.app`.
6. Add the exact `Verified-Runtime: <head>` line and macOS event-routing explanation to the PR body.
7. Push, open a ready PR against `main`, invoke `@codex review` and `@cursor @bugbot review` (plus CodeRabbit when available), address feedback, and do not merge.
8. Append the verified seam and PR URL to the collab file, re-read it, and store WHAT + WHY in BrainLayer.
