# Notch Launcher and Waveform Polish Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Restore launcher-only management controls and make the seven-bar waveform, spinner inset, and black-to-glass fade render correctly across every active-state entry.

**Architecture:** Keep the existing fixed hardware core, reusable wing slots, W2 `WaveformView`, and operational truth. Correct only slot content, stable layout contracts, and rendered capture gates; management controls remain a launcher-only branch.

**Tech Stack:** Swift 6, SwiftUI/AppKit, XCTest, existing `NotchCaptureContrastVerifier`, VoiceLayer capture harness.

---

### Task 1: Launcher-only management state

**Files:**
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceBarNotchContract.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/BarView.swift`
- Test: `flow-bar/Tests/VoiceBarUITests/VoiceBarNotchContractTests.swift`
- Test: `flow-bar/Tests/VoiceBarUITests/BarViewClickabilityTests.swift`

1. Write RED assertions that hover-launcher roles are microphone/history/dictionary and every active state excludes history/dictionary.
2. Write a RED source/behavior assertion that both management controls mount only in the hover-launcher trailing branch and retain the launcher while a popover is open.
3. Run the focused tests and confirm the expected missing-dictionary failures.
4. Restore the prior Dictionary control/popover and its retention/cleanup state only in `.hoverLauncher`.
5. Re-run focused tests GREEN.

### Task 2: Stable waveform viewport and compact padding

**Files:**
- Modify: `flow-bar/Sources/VoiceBarUI/WaveformView.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceBarNotchContract.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceBarPresentation.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceBarNotchView.swift`
- Test: `flow-bar/Tests/VoiceBarUITests/WaveformViewTests.swift`
- Test: `flow-bar/Tests/VoiceBarUITests/VoiceBarNotchContractTests.swift`
- Test: `flow-bar/Tests/VoiceBarUITests/VoiceBarPanelLayoutTests.swift`

1. Write RED assertions for a seven-bar 46×24 pt non-compressible viewport, no internal clip on full-height bars, and symmetric core-facing compact placement whose spinner/waveform delta is ≤2 pt.
2. Run focused tests RED.
3. Add the minimal fixed viewport around the existing renderer; do not change its formulas, bar count, truth inputs, or colors.
4. Replace the hard-coded compact two-point inset with a shared 13.5 pt physical-bezel gutter plus the 14 pt outer inset; place the 16 pt visible fade at the calibrated core edge without charging either inset twice.
5. Run focused tests GREEN.

### Task 3: Rendered clipping and fade gates

**Files:**
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceBarNotchCaptureAudit.swift`
- Modify: `flow-bar/Sources/NotchCaptureContrastVerifier/main.swift`
- Test: `flow-bar/Tests/VoiceBarUITests/VoiceBarNotchCaptureAuditTests.swift`
- Test: `flow-bar/Tests/VoiceBarUITests/BarViewSnapshotArtifactTests.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceBarNotchContract.swift`

1. Read and incorporate every group from `waveform-census-qa.md` when it lands.
2. Add RED synthetic/captured-frame tests that reject transcribing completeness below 95%, bottom-pinned/off-center growth, unequal slot geometry, a spinner/waveform padding delta above 2 pt, and an absent/abrupt seam fade. Retain the pre-existing recording-gain gate without retuning it in Round-2D.
3. Run focused tests RED against canonical `ef4b73c` behavior.
4. Keep the 8.5 pt hardware calibration, translate the 16 pt black-to-glass seam entirely beyond the physical bezel, and wire waveform/fade evidence into the capture verifier.
5. Add a scale-correct first-render handshake: hide until screen/window/root/descendant layers agree, rerasterize on launch and screen/backing changes, and emit a capture receipt.
6. Make the verifier reject a missing/mismatched scale receipt and reject uniformly soft frames by requiring a genuinely sharp native glyph in the same screenshot.
7. Have the lead capture recording→transcribing→speaking and a same-process Dark→Light→Dark leg from the exact artifact; inspect the physical photo/framebuffer pair and record the visual receipt.

### Task 4: Full verification and delivery

**Files:**
- Modify: `openspec/changes/notch-app/tasks.md`
- Update: Round-2C report/contract seam files after exact-head evidence exists.

1. Run focused Swift tests, then the full Swift suite.
2. Run the full Bun suite, typecheck, formatting, and diff checks.
3. Run isolated corpus `10/10`, runtime-control gates, and both terminal paste legs.
4. Build/notarize the exact head without stopping or relaunching the resident.
5. Run worker-owned appearance/status and waveform checks in the isolated QA bottom-left placement (parallel-only, normal window level, capture then terminate). Post the exact artifact and scale-gated runner to the lead for the actual-notch sharpness, birthmark, spinner-inset, and outward-fade gates; this worker does not place another surface on Etan's live notch.
6. Commit intentionally, push the bounded branch, open a PR against current `main`, and post the exact seam before any lead-owned resident swap.

### Task 3A: Compact-state gallery polish

**Files:**
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceBarNotchContract.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceBarNotchView.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/BarView.swift`
- Test: `flow-bar/Tests/VoiceBarUITests/VoiceBarNotchContractTests.swift`
- Test: `flow-bar/Tests/VoiceBarUITests/BarViewClickabilityTests.swift`
- Test: `flow-bar/Tests/VoiceBarUITests/VoiceBarNotchMaterialTests.swift`

1. Preserve the already-landed compact glass composition. Do not infer product blur from the invalid gallery: the live app is 1px-sharp, while historical blur remains launch-conditioned and is addressed by deterministic scale setup/self-check.
2. Write RED assertions for a centered 8 pt stop square in its 20 pt destructive circle, bare secondary actions, and centralized optical glyph metrics.
3. Run the focused tests and confirm the current mixed filled/bare control implementation fails.
4. Write a RED layout assertion that hover, recording, and compact-status slots use the same visible core gutter and core-facing alignment contract.
5. Run the focused tests and confirm the current state-private inset calculation has no shared contract.
6. Implement the minimum control-optics and slot-layout changes, then rerun focused tests GREEN.
7. Preserve collapsed idle's zero-surface/zero-software-core invariant; document the historical gallery's uniform menu-bar wash as capture-only rather than painting a false software notch.
8. Re-run the exact-candidate gallery through the lead-owned isolated capture workflow only after the scale receipt and absolute native-sharpness preflight pass; grade all compact states plus the teleprompter reference.

### Task 3B: Round-2D measured convergence

**Files:**
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceBarNotchContract.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceBarNotchMaterial.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceBarNotchView.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceBarPresentation.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/BarView.swift`
- Test: `flow-bar/Tests/VoiceBarUITests/VoiceBarNotchContractTests.swift`
- Test: `flow-bar/Tests/VoiceBarUITests/VoiceBarNotchScreenGeometryTests.swift`
- Test: `flow-bar/Tests/VoiceBarUITests/VoiceBarPresentationTests.swift`
- Test: `flow-bar/Tests/VoiceBarUITests/BarViewClickabilityTests.swift`
- Test: `flow-bar/Tests/VoiceBarUITests/VoiceBarNotchContrastTests.swift`

1. Write RED contracts for a symmetric 13.5 pt compact core inset, core-facing alignment, no double-counted hardware occlusion, content-fit recording/transcribing widths, and a contained 8 pt stop glyph.
2. Drive `awaitingSecondTap` and model-load status truth in RED tests and require every compact wing label to use the same live primary-label foreground as the glyph path in both appearances.
3. Run the focused tests RED against `f73ed95`; record the expected failures before implementation.
4. Implement only the compact layout, fitted-width, stop-container, and label-foreground changes. Preserve teleprompter geometry and all waveform/truth/gold code byte-for-byte.
5. Use the landed blue-bottom-clip frame report: add a RED that rejects seven varying bars sharing one bottom coordinate, then center each variable-height bar inside an explicit full-height slot. Do not change the processing formula, recording phase, or gold constants.
6. Run focused GREEN, full suites, corpus gates, and exact-head notarization.
7. Use an isolated bundle/socket/defaults capture only: capture light RESULT and same-process appearance toggling during recording, then terminate automatically. Never touch the resident surface.
8. Re-run the banked full-seven, one-pixel sharpness, and contrast-polarity gates; one push to PR #359 and one exact seam post follow only after all evidence passes.
