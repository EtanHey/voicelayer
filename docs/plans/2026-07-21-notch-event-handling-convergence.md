# VoiceBar Notch Event-Handling Convergence Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make VoiceBar capture clicks only on mounted controls, move recording actions out of the macOS right-side system-control band, remove the teleprompter dictionary, and align every waveform through one shared core-relative component.

**Architecture:** Preserve the continuous glass, fixed black hardware core, and nonactivating panel. Replace rendered-surface hit testing with pure state/configuration-driven control rectangles, keep hover expansion/retention separate, move recording actions to the leading wing, and make recording/transcribing/speaking use one waveform component and one 24-point core gap.

**Tech Stack:** Swift 6/SwiftUI/AppKit/CoreGraphics, XCTest, Bun, shell verification, Developer ID signing/notarization.

---

### Task 1: Replace glass-surface hit testing with exact control geometry

**Files:**
- Modify: `flow-bar/Tests/VoiceBarUITests/VoiceBarNotchHitRegionTests.swift`
- Modify: `flow-bar/Tests/VoiceBarUITests/VoiceBarPanelLayoutTests.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceBarNotchHitRegion.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceBarPanelLayout.swift`

**Step 1: Write failing pure-geometry tests**

Add cases for:

- launcher mic/history/dictionary centers hit and adjacent glass does not;
- VAD recording exposes exactly hold/cancel/stop on the leading side;
- PTT exposes cancel/stop and no hold placeholder;
- transcribing exposes only cancel after the shared waveform slot;
- teleprompter exposes only its mounted bottom-row controls and never a dictionary/body rectangle;
- a point 1 point outside each 20×20 control, plus representative old wing/body points, passes through;
- rebuilding the region for successive states removes all old rectangles.

Use a configuration value with explicit booleans/counts rather than inferring optional controls from wing width.

**Step 2: Run RED**

Run:

```bash
swift test --package-path flow-bar --filter VoiceBarNotchHitRegionTests
swift test --package-path flow-bar --filter VoiceBarPanelLayoutTests
```

Expected: FAIL because the existing region is the full rendered shape and `VoiceBarPanelLayout` has no independent interaction/hover predicates.

**Step 3: Implement the minimal geometry contract**

Add `VoiceBarNotchInteractionConfiguration` and make `VoiceBarNotchHitRegion` produce only mounted control rectangles from the approved constants. Keep a separate visible/core hover region. Update `VoiceBarPanelLayout.make` to accept the interaction configuration and expose:

```swift
func containsInteractiveContent(_ point: CGPoint) -> Bool
func containsHoverExpansion(_ point: CGPoint) -> Bool
func containsHoverRetention(_ point: CGPoint) -> Bool
func containsVisibleSurface(_ point: CGPoint) -> Bool
```

The interaction path must never include waveforms, text, status-only glyphs, glass, shadows, or empty slots.

**Step 4: Run GREEN**

Run both filtered suites again. Expected: PASS with zero failures.

**Step 5: Commit**

```bash
git add flow-bar/Sources/VoiceBarUI/VoiceBarNotchHitRegion.swift \
  flow-bar/Sources/VoiceBarUI/VoiceBarPanelLayout.swift \
  flow-bar/Tests/VoiceBarUITests/VoiceBarNotchHitRegionTests.swift \
  flow-bar/Tests/VoiceBarUITests/VoiceBarPanelLayoutTests.swift
git commit -m "fix(voicebar): limit notch input to mounted controls"
```

### Task 2: Wire exact input and independent hover through AppKit

**Files:**
- Modify: `flow-bar/Tests/VoiceBarTests/AppLifecycleTests.swift`
- Modify: `flow-bar/Tests/VoiceBarUITests/BarViewClickabilityTests.swift`
- Modify: `flow-bar/Sources/VoiceBar/VoiceBarApp.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/FloatingPanel.swift`

**Step 1: Write failing lifecycle tests**

Prove `PillHostingView.hitTest`, panel context-menu/drag predicates, and `applyPanelMouseEventPassthrough` use `containsInteractiveContent`; hover expansion uses hardware-core/control geometry; retained readback uses visible-surface geometry. Add a stationary-pointer transition test showing an old recording stop location becomes pass-through immediately after transcribing/teleprompter/idle layout installation.

**Step 2: Run RED**

```bash
swift test --package-path flow-bar --filter AppLifecycleTests
swift test --package-path flow-bar --filter BarViewClickabilityTests
```

Expected: FAIL because all paths currently share `containsActiveContent`.

**Step 3: Implement the wiring**

Derive `VoiceBarNotchInteractionConfiguration` from current `VoiceState` in one function and pass it through every `currentPanelLayout()` call. Recompute `ignoresMouseEvents` synchronously after each state/layout change. Preserve `.nonactivatingPanel`, `canBecomeMain == false`, and the absence of `makeKey()`.

**Step 4: Run GREEN and commit**

Run both filtered suites; then review and commit only these files.

### Task 3: Relocate recording actions and remove the teleprompter dictionary

**Files:**
- Modify: `flow-bar/Tests/VoiceBarUITests/BarViewClickabilityTests.swift`
- Modify: `flow-bar/Tests/VoiceBarUITests/VoiceBarNotchContractTests.swift`
- Modify: `flow-bar/Tests/VoiceBarUITests/VoiceBarNotchViewTests.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/BarView.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceBarNotchContract.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceBarPresentation.swift`

**Step 1: Write failing behavior/source tests**

Assert:

- VAD leading content order is prominent destructive stop/cancel/hold; PTT is prominent destructive stop/cancel;
- recording trailing content contains only the shared waveform;
- the interaction centers match the rendered HStack order and 20/6-point metrics;
- teleprompter leading content contains no `vocabularyButton`, dictionary role, or hidden placeholder;
- hover-launcher still mounts `vocabularyButton` and its `Transcription Vocabulary` popover.

**Step 2: Run RED**

```bash
swift test --package-path flow-bar --filter BarViewClickabilityTests
swift test --package-path flow-bar --filter VoiceBarNotchContractTests
swift test --package-path flow-bar --filter VoiceBarNotchViewTests
```

Expected: FAIL on current right-side recording controls and teleprompter dictionary.

**Step 3: Implement minimal layout changes**

Move only interactive recording actions to the leading wing; remove the noninteractive leading recording mic if needed to keep the source of truth singular. Make the right wing waveform-only and use the approved 99.5/73.5/78-point VAD/PTT/waveform widths. Remove the teleprompter dictionary view and role without changing the idle-hover dictionary implementation or the continuous material/morph code.

**Step 4: Run GREEN and commit**

Run the three filtered suites, `git diff --check`, local review, then commit.

### Task 4: Make waveform rendering and placement one shared state-driven component

**Files:**
- Modify: `flow-bar/Tests/VoiceBarUITests/WaveformViewTests.swift`
- Modify: `flow-bar/Tests/VoiceBarUITests/BarViewClickabilityTests.swift`
- Modify: `flow-bar/Tests/VoiceBarUITests/VoiceBarPresentationTests.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/WaveformView.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/BarView.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceBarNotchContract.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceBarPresentation.swift`

**Step 1: Write failing shared-placement tests**

Require one `VoiceBarNotchWaveform` call site, the same 46×24 viewport, a 24-point core gap for recording/transcribing/speaking, no recording-only horizontal padding, no transcribing clear spacer, waveform-first compact speaking order, and unchanged audio truth sources/colors.

Render the three states offscreen and assert the waveform bounding box starts at the same X offset from `geometry.coreOriginX + geometry.coreWidth`.

**Step 2: Run RED**

```bash
swift test --package-path flow-bar --filter WaveformViewTests
swift test --package-path flow-bar --filter VoiceBarPresentationTests
```

Expected: FAIL because current states use three call shapes and three spacing paths.

**Step 3: Implement the component**

Create a state-driven `VoiceBarNotchWaveform` wrapper that selects recording RMS/listening treatment, processing animation, or playback RMS while keeping viewport and external placement invariant. Make it the first trailing element for all waveform states and drive wing width from the same shared constants.

**Step 4: Run GREEN and commit**

Run Waveform, Presentation, Clickability, Contract, and PanelLayout filtered suites; inspect render artifacts; then commit.

### Task 5: Add offscreen event-routing acceptance

**Files:**
- Modify: `flow-bar/Tests/VoiceBarTests/AppLifecycleTests.swift`
- Modify: `flow-bar/Tests/VoiceBarUITests/BarViewClickabilityTests.swift`
- Create: `scripts/verify-notch-event-handling.sh`
- Create: `src/__tests__/notch-event-handling-script.test.ts`

**Step 1: Write the failing script contract test**

Require `set -euo pipefail`, `mktemp -d`, unique socket/defaults paths, explicit offscreen coordinates at or beyond `(-20000,-20000)`, parallel-instance registration, exact PID capture/cleanup, and no `/Applications/VoiceBar.app`, `pkill`, bottom-left, or visible-corner placement.

**Step 2: Run RED**

```bash
bun test src/__tests__/notch-event-handling-script.test.ts
```

Expected: FAIL because the acceptance runner does not exist.

**Step 3: Implement the runner and offscreen acceptance**

Build or accept an explicit isolated app path; launch the real app on unique sockets/defaults offscreen; drive recording/transcribing/speaking/idle socket states; run the AppKit event suites that send real mouse events to control centers and pass-through points; assert the isolated marker/socket disappear after exact-PID termination. Render state artifacts through offscreen hosts for pixel inspection without moving any QA app into the user's visible desktop.

**Step 4: Run GREEN and commit**

Run the script contract test and the runner against a temporary app. Open every emitted frame before recording a visual receipt. Commit the harness and tests.

### Task 6: Full verification and exact-head artifact

**Files:**
- Verify: all changed files
- Generate: `.verified/verified-runtime-fix-notch-363c-event-handling-<short-sha>.txt`

**Step 1: Re-read the brief and requirements checklist**

Confirm every event-handling, dictionary, waveform, sacred-material/morph, isolation, runtime, and PR-body requirement has direct evidence.

**Step 2: Run full local suites**

```bash
swift test --package-path flow-bar
bun test
bun run typecheck
bash flow-bar/build-app.sh --install-path "$isolated_root/VoiceBar.app" --no-stop --no-relaunch
bash scripts/verify-notch-event-handling.sh "$isolated_root/VoiceBar.app"
bash scripts/verify-notch-glass-readability.sh "$isolated_root/VoiceBar.app"
bash scripts/verify-notch-teleprompter-dismissal.sh "$isolated_root/VoiceBar.app"
```

All app invocations must remain isolated/offscreen; if either legacy visual script only supports visible bottom-left placement, update it or record it as inadmissible rather than violating the brief.

**Step 3: Commit the verified implementation head**

Run local review with a bounded timeout, address verified major findings, then commit any final test/receipt changes.

**Step 4: Run exact-head corpus/runtime verification**

```bash
bash scripts/voicelayer-verify.sh --corpus 10
```

Expected: a `.verified` artifact whose first line is exactly `Verified-Runtime: $(git rev-parse HEAD)`.

**Step 5: Build and verify the exact-head notarized app**

Build to a temporary non-resident path with `VOICEBAR_NOTARY_PROFILE=notary-layers`; verify embedded `GitCommit`, strict/deep code signature, Gatekeeper assessment, staple validation, and `syspolicy_check distribution`. Re-run the offscreen event runner against that exact app.

### Task 7: Ready PR, review loop, and collab seam

**Files:**
- Modify: `/Users/etanheyman/Gits/orchestrator/collab/2026-07-17-voicelayer-notch-w1-w2.md`

**Step 1: Push and create a ready-for-review PR against `main`**

Include root cause, geometry table, test counts, offscreen verification receipts, notarization identity, and a standalone `Verified-Runtime: <full-head-sha>` line. State that the resident app was untouched and the lead owns the swap/merge.

**Step 2: Invoke required reviewers**

```bash
gh pr comment <N> --body "@coderabbitai review"
gh pr comment <N> --body "@codex review"
gh pr comment <N> --body "@cursor @bugbot review"
```

**Step 3: Address feedback**

Read every review/check, investigate before changing code, reply to every critical/high/major finding, fix valid issues test-first, push, and request re-review. Do not merge.

**Step 4: Post and verify the collab seam**

Append a real-clock timestamp, PR URL, exact head, root cause, changed interaction/waveform architecture, suite counts, visual/behavioral receipts, notarization evidence, review state, and explicit `NO MERGE — lead owns resident swap`. Re-read the appended content before reporting `TASK_DONE`.
