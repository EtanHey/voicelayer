# Notch #363c Vertical Hit-Offset Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Align VoiceBar's rendered notch pixels, exact control hit regions, hover routing, and window pass-through boundary vertically without changing the horizontal or shape contracts from #370/#372.

**Architecture:** Keep `VoiceBarPanelLayout` in unflipped AppKit window coordinates. `NSEvent.locationInWindow` already arrives in that coordinate space, so forward it unchanged through the hosting view's pointer/hover path. SwiftUI's flipped hosting coordinates remain private to AppKit/SwiftUI hit dispatch and are not fed into the window-geometry providers.

**Tech Stack:** Swift 6, AppKit, SwiftUI, XCTest, Bun, existing offscreen VoiceBar QA/corpus/notarization scripts.

---

### Task 1: Lock the flipped-coordinate regression

**Files:**
- Modify: `flow-bar/Tests/VoiceBarUITests/BarViewClickabilityTests.swift`
- Modify: `flow-bar/Tests/VoiceBarUITests/VoiceBarHoverHysteresisTests.swift`

1. Add an attached `PillHostingView` regression that synthesizes `mouseMoved` at the visible top edge of compact controls in window coordinates.
2. Assert the provider receives the unchanged unflipped window point and rejects a point in the bottom-only shadow lane.
3. Keep action coverage at one point inside the upper edge of recording and teleprompter control rectangles.
4. Run the focused test and confirm it fails because providers currently receive the flipped local Y.

### Task 2: Remove the redundant hosting-view flip

**Files:**
- Modify: `flow-bar/Sources/VoiceBarUI/FloatingPanel.swift`
- Modify: `flow-bar/Sources/VoiceBar/VoiceBarApp.swift`

1. Forward `mouseEntered` and `mouseMoved` `event.locationInWindow` directly to the rendered/interactive/hover/passthrough providers.
2. Leave `hitTest` and SwiftUI descendant dispatch unchanged; AppKit already supplies the expected point for that path.
3. Leave the global panel-window pointer route unchanged because it already produces the same unflipped window coordinates.
4. Run the focused tests and confirm the top edge is admitted while the below-surface shadow lane passes through.

### Task 3: Prove every state and exact-head runtime

**Files:**
- Modify as needed: existing offscreen acceptance runner/tests under `flow-bar/Tests/`
- Generate: `.verified/verified-runtime-<branch>-<short-sha>.txt`

1. Exercise idle, recording, transcribing, speaking, and teleprompter surfaces, with real top-edge clicks for recording controls plus rendered-surface and shadow-lane boundary probes.
2. Run full Swift, Bun, typecheck, corpus, and terminal verification gates.
3. Build the isolated app, keep it fully offscreen at `(-20000, -20000)`, send real clicks to visible control top edges, and inspect every receipt/frame.
4. Notarize/staple the exact head, stage the matching runtime artifact, and keep version 2.1.17.

### Task 4: Publish the worker seam

**Files:**
- Modify: `/Users/etanheyman/Gits/orchestrator/collab/2026-07-17-voicelayer-notch-w1-w2.md`

1. Run bounded local CodeRabbit review, then commit and push the scoped change.
2. Open a ready PR against `main`, include `Verified-Runtime: <head>`, and invoke Codex plus Cursor/Bugbot (and available reviewers).
3. Investigate, fix/reply, and re-request review as needed; do not merge.
4. Post the PR/head/test evidence and the macOS coordinate explanation to the collab file and BrainLayer.
