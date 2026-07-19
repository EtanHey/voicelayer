# VoiceBar Notch V10 Material-Seam Refinement Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make the fixed black camera housing visibly and continuously fade into the native liquid-glass wings while removing teleprompter body/wing seam artifacts.

**Architecture:** A pure seam descriptor owns the mirrored nonlinear gradient stops and state-specific compact radius. `VoiceBarNotchView` reuses that veil for compact and teleprompter states. `VoiceBarNotchContinuousShape` becomes one concave closed outline so one material modifier produces one edge treatment.

**Tech Stack:** Swift 6.3, SwiftUI, CoreGraphics, XCTest, existing isolated actual-notch capture harness.

---

### Task 1: Lock the seam and radius contracts

**Files:**
- Modify: `flow-bar/Tests/VoiceBarUITests/VoiceBarNotchMaterialTests.swift`
- Modify: `flow-bar/Tests/VoiceBarUITests/VoiceBarNotchContractTests.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceBarNotchMaterial.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceBarNotchContract.swift`

**Step 1: Write the failing tests**

Require the 16-point mirrored veil to start transparent and finish at opacity `1.0` on the hardware edge. Require hover radius `11` and recording/compact radius `15`.

**Step 2: Run the focused tests and verify RED**

Run: `swift test --package-path flow-bar --filter 'VoiceBarNotchMaterialTests|VoiceBarNotchContractTests'`

Expected: FAIL because opacity/stops and state-specific radius do not exist.

**Step 3: Implement the minimum pure descriptors**

Add value-only gradient stops and the radius resolver. Do not touch W2 state or renderer files.

**Step 4: Re-run focused tests**

Expected: PASS.

### Task 2: Make the teleprompter one contour and reuse the seam veil

**Files:**
- Modify: `flow-bar/Tests/VoiceBarUITests/VoiceBarNotchShapeTests.swift`
- Modify: `flow-bar/Tests/VoiceBarUITests/VoiceBarNotchViewTests.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceBarNotchShape.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceBarNotchView.swift`

**Step 1: Write the failing tests**

Count CoreGraphics move elements to require one teleprompter subpath. Require both compact presentations (hover launcher, recording, and compact status) and teleprompter presentation to use the shared veil contract, with exactly two core-edge veils whenever wings are visible.

**Step 2: Run focused tests and verify RED**

Run: `swift test --package-path flow-bar --filter 'VoiceBarNotchShapeTests|VoiceBarNotchViewTests'`

Expected: FAIL because the shape has three subpaths and teleprompter has no seam overlay.

**Step 3: Implement one concave outline and shared overlay**

Trace the union boundary once around the centered hardware cutout and lower body. Position the two mirrored veils from `VoiceBarNotchShapeLayout.coreRect` and preserve the fixed black core at z-index 10.

**Step 4: Re-run focused tests**

Expected: PASS.

### Task 3: Verify and reshoot around the actual notch

**Files:**
- Update ignored receipts under: `docs.local/notch-v10-native-port/`
- Modify: `<orchestrator-repo>/docs.local/handoffs/2026-07-17-notch-w1-native-port-REPORT.md`
- Append: `<orchestrator-repo>/collab/2026-07-17-voicelayer-notch-w1-w2.md`

**Step 1: Run focused and full verification**

Run Swift focused tests, full Swift, serialized Bun, typecheck, and `git diff --check`. Record exact counts from fresh output.

**Step 2: Build an isolated exact-head app**

Build/sign/notarize only the isolated bundle. Never replace or inspect `/Applications/VoiceBar.app`.

**Step 3: Capture affected states**

Capture hover, recording, compact status, and teleprompter in Dark, Light, and Reduced Motion around the physical built-in-display notch. Each cycle is launch → screenshot → exact-PID termination.

**Step 4: Commit, push, and repin PR #352**

Push the clean commit, update the standalone `Verified-Runtime:` marker and report, and explicitly post the three W2 carryover confirmations. Keep merge blocked until #351 merges and this branch is rebased onto merged main.
