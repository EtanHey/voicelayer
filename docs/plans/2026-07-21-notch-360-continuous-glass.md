# Notch #360 Continuous Glass Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship one adaptive, readable, continuous notch glass system that remains ready for a later compact-to-panel morph without changing #359's accepted behavior.

**Architecture:** Put one content-bearing `VoiceBarNotchContinuousShape` under a persistent SwiftUI wrapper for every non-idle state. On macOS 26 that wrapper embeds one `NSGlassEffectView` through `NSViewRepresentable`, uses the SwiftUI shape as its mask, hosts the SwiftUI slots as its content, clears the containing window background, and installs active-in-app pointer tracking. Remove the empty expanded material sibling, the fixed dark fill, and the painted `VoiceBarNotchCoreSeamStop` ramp so one real glass surface owns the external wing-to-below-bezel-panel join while the hardware core remains opaque black. Prove the change with a separate test-only backdrop fixture and captured VoiceBar pixels before accepting any visual claim.

**Tech Stack:** Swift 6, AppKit `NSGlassEffectView` bridged into SwiftUI on macOS 26, SwiftUI `.ultraThinMaterial` on macOS 14–25, XCTest, Bun, shell capture harness, Apple notarization. `NSVisualEffectView` is forbidden.

---

### Task 1: Lock the continuous, content-bearing, morph-ready hierarchy

**Files:**
- Modify: `flow-bar/Tests/VoiceBarUITests/VoiceBarNotchViewTests.swift`
- Modify: `flow-bar/Tests/VoiceBarUITests/VoiceBarNotchMaterialTests.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceBarNotchView.swift`

**Step 1: Write the failing hierarchy tests**

Replace the current atomic-removal source assertion with requirements that:

```swift
XCTAssertTrue(body.contains("VoiceBarGlassContainer"))
XCTAssertTrue(body.contains("notchSurface"))
XCTAssertFalse(body.contains("teleprompterSurfaceUnit"))
XCTAssertTrue(surface.contains("VoiceBarNotchContinuousShape"))
XCTAssertTrue(surface.contains("notchSlots"))
XCTAssertEqual(surface.components(separatedBy: "VoiceBarGlassMaterial(").count - 1, 1)
XCTAssertFalse(surface.contains("Color.clear"))
XCTAssertFalse(body.contains("coreEdgeVeils"))
XCTAssertFalse(body.contains("VoiceBarBlackToGlassFade"))
```

Extract balanced source slices for `body`, `notchSurface`, and `notchSlots`, rather than relying on whole-file substring counts. Require the persistent container's slice to contain the visual-state branch, not live only inside compact wings. Require the `notchSurface` slice to own the only material modifier and contain the `notchSlots` call, and require the `notchSlots` slice to contain expanded leading, trailing, and lower slots. Keep whole-file checks for forbidden legacy symbols and duplicate material usage.

**Step 2: Run the focused tests and verify RED**

Run:

```bash
swift test --package-path flow-bar --filter 'VoiceBarNotch(View|Material)Tests'
```

Expected: FAIL because the current expanded material is applied to `Color.clear`, `teleprompterSurfaceUnit` owns two siblings, the glass container is compact-only, and `coreEdgeVeils` still paint the join.

**Step 3: Implement the minimal shared hierarchy**

Move `VoiceBarGlassContainer` outside the compact/teleprompter switch. Replace `teleprompterSurface`, `teleprompterSurfaceUnit`, and `teleprompterSlots` with:

```swift
private var notchSurface: some View {
    let shape = VoiceBarNotchContinuousShape(
        geometry: presentation.geometry,
        compactOuterCornerRadius: compactOuterCornerRadius
    )
    return notchSlots
        .modifier(VoiceBarGlassMaterial(shape: shape, appearance: appearance))
        .contentShape(shape)
}
```

Use one `notchSlots` layout for the two top slots plus optional lower content. Remove `coreEdgeVeils`, `VoiceBarBlackToGlassFade`, `VoiceBarNotchCoreSeamStop`, and their descriptor counts; the native material replaces the painted ramp. Keep the black hardware core outside the material modifier and at its existing z-index. Keep `.transition(.identity)` as current policy without adding any test that makes opacity fade the only future path.

**Step 4: Run focused tests and verify GREEN**

Run the Task 1 focused command. Expected: 0 failures.

**Step 5: Commit**

```bash
git add flow-bar/Sources/VoiceBarUI/VoiceBarNotchView.swift \
  flow-bar/Tests/VoiceBarUITests/VoiceBarNotchViewTests.swift \
  flow-bar/Tests/VoiceBarUITests/VoiceBarNotchMaterialTests.swift
git commit -m "refactor(voicebar): unify notch glass ownership"
```

### Task 2: Replace degraded SwiftUI glass with the proven AppKit glass host

**Files:**
- Modify: `flow-bar/Tests/VoiceBarUITests/VoiceBarNotchMaterialTests.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceBarNotchMaterial.swift`

**Step 1: Write the failing material-recipe tests**

Add a pure descriptor for native glass tint and host policy. Require both appearances to use a neutral white tint with alpha `0.06`, no fixed filled overlay, and the AppKit host on macOS 26:

```swift
for appearance in [VoiceBarNotchAppearance.dark, .light] {
    let recipe = VoiceBarNotchGlassRecipe.resolve(for: appearance)
    XCTAssertEqual(recipe.tint, VoiceBarRGBA(red: 1, green: 1, blue: 1, alpha: 0.06))
    XCTAssertNil(recipe.nativeOverlay)
}
```

Keep the opaque accessibility fallback and the guarded macOS 14 material fallback.

Add focused source-slice coverage for `VoiceBarGlassMaterial.body`: the macOS 26 slice must use exactly one `VoiceBarAppKitGlassHost`; the representable must create `NSGlassEffectView`, host the SwiftUI content as `contentView`, set the containing window background to clear, mask with `VoiceBarNotchContinuousShape`, and install an `NSTrackingArea` containing `.mouseEnteredAndExited` and `.activeInActiveApp`. The fallback slice must retain `.background(.ultraThinMaterial, in: shape)`. The entire notch material source must not contain `NSVisualEffectView` or SwiftUI `.glassEffect` in the Phase 1 product path.

**Step 2: Run the focused test and verify RED**

Run:

```bash
swift test --package-path flow-bar --filter VoiceBarNotchMaterialTests
```

Expected: FAIL because the current macOS 26 implementation uses SwiftUI `.glassEffect`, which degrades inside the production `.nonactivatingPanel`, and Dark also resolves to a black 0.22 tint plus black 0.14 overlay.

**Step 3: Implement the minimal recipe**

Add `VoiceBarNotchGlassRecipe` and make the macOS 26 path use a generic representable:

```swift
VoiceBarAppKitGlassHost(shape: shape, tint: recipe.tint) {
    content
}
```

Its `NSGlassEffectView` must use `.regular`, a shape mask, hosted SwiftUI content, a clear containing-window background, and active-in-app tracking. Do not add a native filled overlay or any `NSVisualEffectView` path. Preserve the SwiftUI `.ultraThinMaterial` fallback and its readability veil until it can be runtime-graded on macOS 14–25.

**Step 4: Run the focused tests and verify GREEN**

Run the Task 2 focused command. Expected: 0 failures.

**Step 5: Commit**

```bash
git add flow-bar/Sources/VoiceBarUI/VoiceBarNotchMaterial.swift \
  flow-bar/Tests/VoiceBarUITests/VoiceBarNotchMaterialTests.swift
git commit -m "fix(voicebar): restore adaptive notch glass"
```

If real dismissal frames show the WindowServer glass fade outliving hosted text, add a content-first playback-edge commit policy: clear/flush the hosted content, yield one frame, and order the panel out after a bounded 50 ms delay. This delay is only an atomic-dismissal safeguard; it must not become the compact↔teleprompter morph mechanism.

### Task 3: Add deterministic readability and wing-contrast pixel audits

**Files:**
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceBarNotchCaptureAudit.swift`
- Modify: `flow-bar/Tests/VoiceBarUITests/VoiceBarNotchCaptureAuditTests.swift`
- Modify: `flow-bar/Sources/NotchCaptureContrastVerifier/main.swift`

**Step 1: Write failing pure-audit tests**

Add tests for fail-closed empty ROIs; teleprompter interior SD `10.01` failing and `10.00` passing; text contrast below 4.5 failing and at/above 4.5 passing; wing contrast below 3.0 failing; wing contrast below the same-frame native reference failing even when above 3.0; and all three settled frames being required.

Use real pixel arrays constructed only to unit-test arithmetic; these tests do not substitute for Task 5's captured-pixel gate.

**Step 2: Run the audit tests and verify RED**

Run:

```bash
swift test --package-path flow-bar --filter VoiceBarNotchCaptureAuditTests
```

Expected: FAIL because no steady-state glass readability audit exists.

**Step 3: Implement minimal audit data types and calculations**

Add a fail-closed result that retains each settled frame's interior SD, text contrast, wing contrast, and native-reference contrast, and also reports frame count, maximum interior SD, minimum text contrast, minimum wing contrast, and minimum native-reference contrast. Reuse `VoiceBarContrast.ratio`, the existing median helpers, and existing RGB/luma image types. Require `wingContrast >= nativeReferenceContrast` within every individual frame before aggregating minima; independently aggregated minima are not a valid parity proof.

Add `--glass-readability-only` to `NotchCaptureContrastVerifier` with explicit paths and normalized ROIs for teleprompter, black compact, bright compact, and native-reference regions. Print one parseable verdict line and exit nonzero on any failed threshold.

**Step 4: Run audit tests and build the verifier**

Run:

```bash
swift test --package-path flow-bar --filter VoiceBarNotchCaptureAuditTests
swift build -c release --package-path flow-bar --product NotchCaptureContrastVerifier
```

Expected: tests pass and verifier build exits 0.

**Step 5: Commit**

```bash
git add flow-bar/Sources/VoiceBarUI/VoiceBarNotchCaptureAudit.swift \
  flow-bar/Tests/VoiceBarUITests/VoiceBarNotchCaptureAuditTests.swift \
  flow-bar/Sources/NotchCaptureContrastVerifier/main.swift
git commit -m "test(voicebar): grade glass readability from pixels"
```

### Task 4: Build the isolated real-backdrop capture harness

**Files:**
- Modify: `flow-bar/Package.swift`
- Create: `flow-bar/Sources/NotchGlassBackdropFixture/main.swift`
- Create: `scripts/verify-notch-glass-readability.sh`
- Create: `src/__tests__/notch-glass-readability-script.test.ts`

**Step 1: Write the failing script contract test**

Require the script to use `set -euo pipefail`, `mktemp -d`, unique VoiceLayer socket/defaults paths, exact captured PIDs, cleanup traps, no `/Applications/VoiceBar.app`, no fixed production socket, three fixture modes (`busy`, `black`, `bright`), three settled frames per state, and the release verifier's `--glass-readability-only` mode.

Run:

```bash
bun test src/__tests__/notch-glass-readability-script.test.ts
```

Expected: FAIL because the script does not exist.

**Step 2: Add the controlled AppKit backdrop fixture**

Add a package executable that opens one nonactivating normal-level window at the isolated capture coordinates. It must support `busy` terminal-like rows and columns; uniform `black`; a 0.82/1.0 `bright` checker; a fixed AppKit system-symbol reference outside the VoiceBar bounds; and a JSON ready receipt containing PID, mode, and frame.

The helper is test-only and must never use VoiceLayer sockets or resident identifiers. AppKit owns only the controlled test window and reference glyph; it must not provide, wrap, or emulate the VoiceBar material.

**Step 3: Add the exact-PID capture runner**

Build/run the fixture and the supplied VoiceBar app on unique sockets. Drive real `recording` and `speaking` events, wait for render-scale readiness, capture three settled PNGs for busy teleprompter and each compact fixture, then run the verifier. Re-run the existing dismissal harness on the same app. Kill only the two captured PIDs and remove only the exact temporary runtime directory.

**Step 4: Run contract tests and shell syntax**

Run:

```bash
bun test src/__tests__/notch-glass-readability-script.test.ts
bash -n scripts/verify-notch-glass-readability.sh
swift build -c release --package-path flow-bar --product NotchGlassBackdropFixture
```

Expected: all commands exit 0.

**Step 5: Commit**

```bash
git add flow-bar/Package.swift flow-bar/Sources/NotchGlassBackdropFixture/main.swift \
  scripts/verify-notch-glass-readability.sh \
  src/__tests__/notch-glass-readability-script.test.ts
git commit -m "test(voicebar): capture glass over real backdrops"
```

### Task 5: Prove RED on main and GREEN on the implementation with real pixels

**Files:**
- Store untracked/local receipts under: `docs.local/qa/notch-360-glass/`

**Step 1: Build an untouched-main comparison app**

Resolve and record `origin/main^{commit}` first. Use that pinned SHA for a temporary detached comparison worktree, build with `flow-bar/build-app.sh --no-stop --no-relaunch` into a temporary bundle, and run the new real-pixel harness.

Expected RED: the archived regression must reproduce as either teleprompter interior SD above 10 or wing/native-reference contrast parity failure. Record the pinned SHA beside the exact regression metric line in the receipt. Remove only the temporary comparison worktree after capturing its receipts.

**Step 2: Build the candidate without touching the resident**

Run `bash flow-bar/build-app.sh --install-path /absolute/temporary/path/VoiceBar.app --no-stop --no-relaunch`. Never install or launch `/Applications/VoiceBar.app`.

**Step 3: Run the real-pixel harness on the candidate**

Run:

```bash
bash scripts/verify-notch-glass-readability.sh /absolute/path/to/VoiceBar.app \
  docs.local/qa/notch-360-glass/candidate
bash scripts/verify-notch-teleprompter-dismissal.sh /absolute/path/to/VoiceBar.app \
  docs.local/qa/notch-360-glass/dismissal
```

Expected GREEN: three of three settled frames per state; maximum lower-body SD at most 10; text at least 4.5:1; compact glyphs at least 3.0:1 and no worse than the native reference over black and bright; zero dismissal violations.

**Step 4: Open every produced frame**

Inspect every PNG at original resolution. Reject clipping, doubled tint, a seam between top wings and lower panel, opaque-card appearance, detached text, #359 geometry drift, waveform drift, or any surviving helper/app process.

**Step 5: Prove the captured-pixel regression remains sensitive**

Run the parent material/view code in a disposable comparison worktree and confirm the new harness returns RED. Restore the candidate and re-run GREEN. Do not mutate the task branch during this proof.

### Task 6: Full exact-head verification and notarization

**Files:**
- Update local verification receipts under: `.verified/` and `docs.local/qa/notch-360-glass/`

**Step 1: Run all suites and static gates**

Run:

```bash
bun test
bun run typecheck
swift test --package-path flow-bar
git diff --check
```

Run the repository's changed-file SwiftFormat gate without rewriting unrelated files.

**Step 2: Run deterministic corpus and runtime gates**

Run the repository's corpus replay manifest for 10/10 and `scripts/voicelayer-verify.sh` in isolated mode. Because `flow-bar/**` changed, complete the VoiceLayer daemon/client runtime gate with worker-owned sockets and the exact-head marker.

**Step 3: Build and notarize exact head**

Build a Developer-ID-signed app with `--no-stop --no-relaunch`, submit to Apple notarization, staple, then verify embedded `GitCommit` equals `git rev-parse HEAD`, strict/deep codesign, Gatekeeper, staple validation, and `syspolicy_check distribution`.

**Step 4: Re-run real pixels on the notarized app**

Run both glass-readability and dismissal harnesses against the notarized exact-head bundle. Open every new frame and record the metric lines and artifact paths.

### Task 7: Review, PR, and contract seam — no merge

**Files:**
- Modify: `${ORCHESTRATOR_REPO}/collab/2026-07-17-voicelayer-notch-w1-w2.md`, where `ORCHESTRATOR_REPO` is the local orchestrator checkout documented by the #360 handoff.

**Step 1: Run bounded local CodeRabbit review**

Run `coderabbit review --agent` with a hard three-minute bound. Fix verified major/critical findings with focused RED→GREEN tests; record any timeout or rate limit accurately.

**Step 2: Commit final verification/docs changes and push**

Confirm every untracked file is accounted for and the worktree is clean. Push `wt/notch-360-glass` to origin.

**Step 3: Open a ready PR against main**

Include root cause, continuous/morph-ready architecture, exact suite counts, RED→GREEN real-pixel metrics, all visual verification receipts, notarized artifact identity, and explicit `NO MERGE — lead owns release/resident swap`.

**Step 4: Invoke hosted reviewers**

Post `@codex review` and `@cursor @bugbot review` as required by the repository, plus available CodeRabbit/Greptile reviewers. Wait at least 120 seconds before the first review check. Read all comments and reply to every critical/high/major finding. Push fixes and request re-review, with no more than three rounds.

**Step 5: Post the contract seam**

Append a clock-stamped seam with PR URL, exact head, root cause, changed architecture, real-pixel metrics, suite/corpus/runtime counts, notarization receipt, review status, isolation proof, and the explicit no-merge handoff. Re-read the appended content before reporting it.

**Step 6: Store BrainLayer milestone**

Store WHAT changed and WHY, including the content-bearing glass root cause, persistent morph-ready container, real-pixel thresholds, PR/head, and resident-swap hold.
