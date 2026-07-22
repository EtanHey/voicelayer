# Virtual Notch on External Displays Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Anchor VoiceBar to a centered software notch on notch-less screens while preserving the existing hardware-notch rendering and #370/#372/#373 event-routing contract.

**Architecture:** Extend the existing injectable `VoiceBarNotchScreenMetrics` resolver so it positively identifies hardware notches, derives each screen's menu-bar height, and exposes a virtual-idle core height for flat displays. Carry that display mode through the existing presentation model so the one shared SwiftUI notch shell can paint a black idle core only for virtual notches. Reuse `VoiceBarPanelLayout.windowFrame(anchoredTo:)` for both hardware and virtual notches; do not modify the hit-region predicates or AppKit coordinate forwarding.

**Tech Stack:** Swift 6, AppKit (`NSScreen`, `NSPanel`, screen-parameter notifications), SwiftUI, XCTest.

---

### Task 1: Resolve hardware versus virtual notch geometry

**Files:**
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceBarNotchScreenGeometry.swift`
- Test: `flow-bar/Tests/VoiceBarUITests/VoiceBarNotchScreenGeometryTests.swift`

**Step 1: Write the failing tests**

Add injected-screen tests that require both `safeAreaTop > 0` and valid auxiliary top areas for a hardware notch. Add a flat-display case with a non-zero screen origin and a 24pt menu bar, asserting a centered 185pt virtual housing and a 24pt idle software-core height.

**Step 2: Run the focused tests to verify they fail**

Run: `swift test --package-path flow-bar --filter VoiceBarNotchScreenGeometryTests`

Expected: FAIL because metrics do not accept `visibleFrame`, hardware detection ignores `safeAreaTop`, and no virtual idle height is exposed.

**Step 3: Implement the minimal geometry decision**

Add `visibleFrame` to `VoiceBarNotchScreenMetrics`. Resolve hardware mode only when the safe-area inset and both valid auxiliary areas agree. Otherwise derive menu-bar height from `frame.maxY - visibleFrame.maxY`, place the synthetic housing at `frame.midX`, and expose that height only as the virtual collapsed core height.

**Step 4: Run the focused tests to verify they pass**

Run: `swift test --package-path flow-bar --filter VoiceBarNotchScreenGeometryTests`

Expected: PASS.

### Task 2: Render a minimal virtual idle core without changing hardware rendering

**Files:**
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceBarNotchContract.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceBarNotchPresentationModel.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceBarNotchView.swift`
- Test: `flow-bar/Tests/VoiceBarUITests/VoiceBarNotchViewTests.swift`
- Test: `flow-bar/Tests/VoiceBarUITests/VoiceBarPanelLayoutTests.swift`
- Test: `flow-bar/Tests/VoiceBarUITests/VoiceBarNotchPresentationModelTests.swift`

**Step 1: Write the failing tests**

Assert that a virtual collapsed presentation has exactly the injected menu-bar height, one opaque fixed core, no interactive controls, a visible core hit region, and transparent margins. Assert that the default/hardware collapsed presentation retains its existing 32pt geometry and draws zero software cores. Assert that updating the presentation model from hardware to virtual mode changes the presentation even when other operational inputs are unchanged.

**Step 2: Run the focused tests to verify they fail**

Run: `swift test --package-path flow-bar --filter 'VoiceBar(NotchView|PanelLayout|NotchPresentationModel)Tests'`

Expected: FAIL because presentation does not yet carry virtual-idle core geometry/rendering.

**Step 3: Implement the minimal presentation and rendering change**

Add an optional virtual idle core height with a hardware-default `nil`. Use it only when resolving `.idle`; all non-idle and all hardware geometry keep the existing `VoiceBarNotchContract.topHeight`. Paint a black `VoiceBarNotchHardwareCoreShape` in idle only when the virtual height is present, leaving the existing non-idle `fixedHardwareCore` branch byte-for-byte unchanged.

**Step 4: Run the focused tests to verify they pass**

Run: `swift test --package-path flow-bar --filter 'VoiceBar(NotchView|PanelLayout|NotchPresentationModel)Tests'`

Expected: PASS.

### Task 3: Anchor flat screens and follow display changes

**Files:**
- Modify: `flow-bar/Sources/VoiceBar/VoiceBarApp.swift`
- Test: `flow-bar/Tests/VoiceBarTests/AppLifecycleTests.swift`

**Step 1: Write the failing tests**

Add lifecycle coverage that the screen metrics include `visibleFrame`, flat-display layout and positioning use `windowFrame(anchoredTo:)`, flat idle no longer forces `keepsIdleExpanded`, display-parameter notifications re-run screen selection and mode resolution, and anchored virtual notches cannot be dragged.

**Step 2: Run the focused tests to verify they fail**

Run: `swift test --package-path flow-bar --filter AppLifecycleTests`

Expected: FAIL because flat displays still use saved pill placement and force expanded idle.

**Step 3: Implement the minimal AppKit wiring**

Pass `screen.visibleFrame` into the metrics resolver and the virtual idle height into the presentation model. For non-isolated windows, use the existing geometry-derived anchored frame on both screen kinds. Keep the existing screen-follow selection and `NSApplication.didChangeScreenParametersNotification`, but make the notification path re-resolve the target screen before laying out the panel. Disable free dragging for both physical and virtual notch anchors.

**Step 4: Run the focused tests to verify they pass**

Run: `swift test --package-path flow-bar --filter AppLifecycleTests`

Expected: PASS.

### Task 4: Verify the complete change and publish the worker PR

**Files:**
- Verify only: `flow-bar/**`
- Do not modify: `README.md`, `CHANGELOG.md`, version files, `/Applications/VoiceBar.app`

**Step 1: Run full automated verification**

Run:
- `swift test --package-path flow-bar`
- `bun test $(git ls-files 'src/__tests__/*.test.ts')`
- `bash flow-bar/build-app.sh` with an explicit non-resident output path if supported; otherwise use `swift build --package-path flow-bar` so the resident app is not replaced.

Expected: all tracked tests pass and the Swift app builds.

**Step 2: Run isolated visual/runtime QA**

Launch only an isolated QA instance using an isolated socket and `QA_VOICEBAR_CAPTURE_OFFSCREEN=1` at `-20000,-20000`; never replace `/Applications/VoiceBar.app`. Exercise the AppKit screen-mode decision through injected metrics and capture any safe visible fixture needed for pixel inspection. Exit the QA process and confirm it released the microphone.

**Step 3: Review and commit**

Run bounded local CodeRabbit review, inspect the complete diff, and commit only the plan, Swift sources, and Swift tests. Do not include unrelated worktree files.

**Step 4: Push and open a ready-for-review PR against `main`**

Push `fix/virtual-notch-external-display`, create the PR, and request `@codex review` plus `@cursor @bugbot review` (and CodeRabbit if available). Read and address all actionable feedback. Do not merge.

**Step 5: Post the seam and store the decision**

Update `/Users/etanheyman/Gits/orchestrator/collab/2026-07-17-voicelayer-notch-w1-w2.md` with the PR URL, detection rule, collapsed-cap rationale, AppKit coordinate mechanics, hit-region preservation, and hardware-path regression statement. Store the verified WHAT + WHY in BrainLayer.
