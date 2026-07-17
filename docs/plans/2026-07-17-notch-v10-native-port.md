# VoiceBar Unified-Glass Native Port Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task after the W2 merge gate opens.

**Goal:** Port Etan's “perfect” unified-glass React mock to the native Swift VoiceBar around the physical MacBook notch without changing VoiceLayer's audio, F5, hold, teleprompter-lifetime, or waveform-truth behavior.

**Architecture:** New contract, screen-geometry, shape, material, motion, hit-region, presentation-model, and shell types own the native notch. Existing `VoiceState`, `WaveformView`, and `TeleprompterView` remain behavioral leaves. Thin adapters in `VoiceBarPresentation`, `VoiceBarPanelLayout`, `BarView`, `FloatingPanel`, and `VoiceBarApp` connect the new shell after rebasing over W2.

**Tech Stack:** Swift 6.3 / SwiftUI / AppKit, macOS 14 minimum with macOS 26 glass availability guards, XCTest/ImageRenderer, existing Bun/Swift/corpus verification.

---

## Hard gate before Task 1

- Confirm W2's combined repair + P0 PR is merged.
- Create a fresh branch/worktree from the resulting `origin/main`.
- Read W2's final changes in `BarView.swift`, `VoiceState.swift`, and `WaveformView.swift` before editing.
- Re-run the focused W2 waveform tests and record the exact green baseline.
- Do not copy native files from this pre-W2 worktree.

Expected precondition: `git merge-base --is-ancestor <W2-merged-head> HEAD` exits 0. If it does not, implementation has not started and no Swift edit is allowed.

### Task 1: Lock the approved geometry, material, motion, and state reducer

**Files:**
- Create: `flow-bar/Sources/VoiceBarUI/VoiceBarNotchContract.swift`
- Create: `flow-bar/Tests/VoiceBarUITests/VoiceBarNotchContractTests.swift`

**Step 1: Write failing contract tests**

Cover:

- idle `185×32`;
- hover `36/64` wings and `285×32` total;
- recording `72/152` wings and `409×32` total;
- teleprompter `76/88` top wings, `349` top width, equal `140/140` body extents, `465×196` lower surface, and `465×228` total;
- `16` fade + `8` clear gap + `8` outer inset, deriving `44/56` teleprompter content slots;
- inverse join radius `5`, waveform slot `72`, one lower layer, no inset frame, no core backdrop;
- spring `310/31/0.72/0`, panel delay `0.05`, content exit `0.12`;
- state precedence: teleprompter > recording > compact status > hover > idle.

Run:

```bash
swift test --package-path flow-bar --filter VoiceBarNotchContractTests
```

Expected RED: missing native contract types.

**Step 2: Implement the minimum pure value types**

Add the enum/struct contract and presentation reducer inputs. Keep all constants out of `Theme.swift`. Do not import AppKit or mutate `VoiceState` in this file.

**Step 3: Re-run the focused test**

Expected GREEN with exact contract assertions.

### Task 2: Resolve physical-notch screen geometry and window/hit bounds

**Files:**
- Create: `flow-bar/Sources/VoiceBarUI/VoiceBarNotchScreenGeometry.swift`
- Create: `flow-bar/Sources/VoiceBarUI/VoiceBarNotchHitRegion.swift`
- Create: `flow-bar/Tests/VoiceBarUITests/VoiceBarNotchScreenGeometryTests.swift`
- Create: `flow-bar/Tests/VoiceBarUITests/VoiceBarNotchHitRegionTests.swift`

**Step 1: Write failing fixtures**

Use the W3 accepted screen fixture: frame `1728×1117`, top safe area `32`, left auxiliary maxX `771`, right auxiliary minX `956`. Assert a measured `185×32` housing, top-centered frame from full `screen.frame`, and zero seam error.

Assert hit-region membership for:

- hover and recording leading/core/trailing strips;
- teleprompter 349-point top bar plus 465-point lower body;
- transparent teleprompter top corners returning false.

**Step 2: Run focused tests and observe RED**

```bash
swift test --package-path flow-bar --filter 'VoiceBarNotchScreenGeometryTests|VoiceBarNotchHitRegionTests'
```

**Step 3: Implement pure resolvers**

Keep `NSScreen` reading behind a small adapter so deterministic fixtures do not need a real display. Use measured auxiliary areas when available and the 185-point reference only as fallback.

**Step 4: Re-run focused tests**

Expected GREEN.

### Task 3: Build the one-surface silhouette and shared material primitive

**Files:**
- Create: `flow-bar/Sources/VoiceBarUI/VoiceBarNotchShape.swift`
- Create: `flow-bar/Sources/VoiceBarUI/VoiceBarNotchMaterial.swift`
- Create: `flow-bar/Tests/VoiceBarUITests/VoiceBarNotchShapeTests.swift`
- Create: `flow-bar/Tests/VoiceBarUITests/VoiceBarNotchMaterialTests.swift`

**Step 1: Write RED structural/path tests**

Assert:

- the fixed core rect never participates in the glass path;
- the teleprompter is one path/layer with a 349-point top bar and centered 465-point body;
- compact wings share one material contract and use outer/top/bottom edge treatment without a transparent border-only shell;
- the mirrored core seam is exactly 16 points;
- macOS 26 glass and macOS 14 material/opaque fallbacks are availability-gated.

**Step 2: Implement the shape and material**

Use direct glass for the single lower body and a glass container for compact sibling wings on macOS 26. Recreate the approved tint/highlight/inner shade/outer shadow through one modifier. Draw the black-to-glass fade as an overlay inside the wing edge; never attach blur/glass to the black core.

**Step 3: Run focused tests and build the package**

```bash
swift test --package-path flow-bar --filter 'VoiceBarNotchShapeTests|VoiceBarNotchMaterialTests'
swift build --package-path flow-bar
```

Expected GREEN/exit 0.

### Task 4: Encode the ordered motion hierarchy

**Files:**
- Create: `flow-bar/Sources/VoiceBarUI/VoiceBarNotchMotion.swift`
- Create: `flow-bar/Tests/VoiceBarUITests/VoiceBarNotchMotionTests.swift`

**Step 1: Write RED plan tests**

Assert opening order `wings → panel(+0.05s) → content`, closing order `content(0.12s) → panel → wings`, fixed-core invariance, interrupt replacement without stacked shells, and reduced-motion ordering without near-zero scaling.

**Step 2: Implement the pure transition plan**

Model phases and delays as data. The shell applies animations; the reducer does not sleep and does not own operational state.

**Step 3: Run focused tests**

```bash
swift test --package-path flow-bar --filter VoiceBarNotchMotionTests
```

Expected GREEN.

### Task 5: Compose the native notch shell and presentation model

**Files:**
- Create: `flow-bar/Sources/VoiceBarUI/VoiceBarNotchPresentationModel.swift`
- Create: `flow-bar/Sources/VoiceBarUI/VoiceBarNotchView.swift`
- Create: `flow-bar/Tests/VoiceBarUITests/VoiceBarNotchViewTests.swift`

**Step 1: Write RED view/source-contract tests**

Require one fixed core, two reusable `VoiceBarGlassWing` slots, one optional continuous lower body, focus/hover launcher parity, content clipping, accessibility labels, and interruption-safe identity.

**Step 2: Implement the shell**

The view accepts typed leading/trailing/lower content and action closures. It owns only visual phase. The presentation model owns hover/focus/reduced-motion and calls one layout-invalidated closure.

**Step 3: Verify focused behavior**

```bash
swift test --package-path flow-bar --filter VoiceBarNotchViewTests
```

Expected GREEN.

### Task 6: Adapt operational state without touching W2's producer/renderer truth

**Files:**
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceBarPresentation.swift`
- Modify: `flow-bar/Tests/VoiceBarUITests/VoiceBarPresentationTests.swift`

**Step 1: Add failing mapping tests**

Cover live teleprompter, retained idle read-back, recording, transcribing release, error, disconnected, confirmation, command/clip marker, queue, hover/focus, and plain idle. Verify teleprompter and recording precedence.

**Step 2: Add the pure adapter**

Return `VoiceBarNotchPresentation` from operational inputs. Do not add fields to `VoiceState`.

**Step 3: Re-run presentation and W2 waveform tests**

```bash
swift test --package-path flow-bar --filter 'VoiceBarPresentationTests|WaveformViewTests|VoiceStateTests'
```

Expected GREEN. Any needed `VoiceState.swift` edit is a scope exception and must be posted before continuing.

### Task 7: Rebase-integrate `BarView` content and controls

**Files:**
- Modify: `flow-bar/Sources/VoiceBarUI/BarView.swift`
- Modify: `flow-bar/Tests/VoiceBarUITests/BarViewClickabilityTests.swift`
- Modify: `flow-bar/Tests/VoiceBarUITests/BarViewSnapshotArtifactTests.swift`

**Step 1: Read and preserve W2's merged seams**

Identify its final recording/playback waveform calls and transcribing hot-stop release overlay. Add tests that those views still mount in the new slots before replacing the capsule.

**Step 2: Write RED interaction tests for the approved states**

Verify Mic, History, Dictionary, the VAD-only HOLD control in the mock's first recording-control slot (and its PTT absence), stop, cancel, teleprompter hide/show/dismiss, replay, and keyboard focus. Assert the core/background does not route the primary action. Do not add a recording-pause command.

**Step 3: Replace only the shell composition**

Move current content into the typed wing/lower slots. Keep `WaveformView` and `TeleprompterView` implementations unchanged. Preserve popovers and action closures.

**Step 4: Run focused tests**

```bash
swift test --package-path flow-bar --filter 'BarViewClickabilityTests|VoiceBarNotchViewTests|WaveformViewTests|TeleprompterContentModelTests'
```

Expected GREEN.

### Task 8: Connect exact layout, hit testing, and physical top anchoring

**Files:**
- Modify: `flow-bar/Sources/VoiceBarUI/VoiceBarPanelLayout.swift`
- Modify: `flow-bar/Sources/VoiceBarUI/FloatingPanel.swift`
- Modify: `flow-bar/Sources/VoiceBar/VoiceBarApp.swift`
- Modify: `flow-bar/Tests/VoiceBarUITests/VoiceBarPanelLayoutTests.swift`
- Modify: `flow-bar/Tests/VoiceBarUITests/VoiceBarPositionLockTests.swift`

**Step 1: Replace obsolete capsule-layout assertions with RED notch assertions**

Assert exact approved visible bounds, shadow-safe window bounds, hit-region pass-through, top anchoring from full screen frame, display-change recomputation, and nonactivating panel behavior.

**Step 2: Wire the presentation model through AppKit**

`VoiceBarApp` owns one model, passes it to `BarView`, recomputes layout on hover/focus/state/display changes, and supplies point hit testing to hosting/panel classes. Use the notch-specific status-bar-equivalent level proven by W3 while preserving `.nonactivatingPanel`, all-Spaces, fullscreen-auxiliary, stationary, no AppKit shadow, and no activation on controls.

**Step 3: Run focused layout/window tests**

```bash
swift test --package-path flow-bar --filter 'VoiceBarPanelLayoutTests|VoiceBarPositionLockTests|BarViewClickabilityTests'
```

Expected GREEN.

### Task 9: Full regression and isolated pixel receipts

**Files:**
- Modify: `flow-bar/Tests/VoiceBarUITests/BarViewSnapshotArtifactTests.swift`
- Create under ignored receipts: `docs.local/notch-v10-native-port/`

**Step 1: Run all automated verification**

```bash
bun test
swift test --package-path flow-bar
bun run typecheck
git diff --check
```

Record exact pass/fail/skip counts from fresh output.

**Step 2: Build only an isolated app**

```bash
bash flow-bar/build-app.sh \
  --install-path /tmp/VoiceBar-notch-v10-native.app \
  --no-stop --no-relaunch
```

Launch with isolated sockets/state paths. Never stop or replace the resident app/daemon.

**Step 3: Capture and inspect the complete matrix**

Capture idle, hover, recording quiet/loud, transcribing release, live teleprompter, retained read-back, and interrupted close/open in Light, Dark, and Reduced Motion with another app frontmost. Inspect every selected image at original resolution.

Compare geometry and material side-by-side with the approved React mock. Record housing seam geometry, core movement (must be zero), silhouette bounds, fade width, content-safe insets, layer count, and focus/hit behavior. Apply the DynamicLake bar as the polish acceptance check, not as a replacement pixel target.

**Step 4: Exact cleanup**

Terminate only the captured isolated PID and remove only `/tmp/VoiceBar-notch-v10-native.app` plus its explicitly named isolated paths. Verify no isolated process/socket remains.

### Task 10: Release gate and handoff

**Files:**
- Update: `openspec/changes/notch-app/tasks.md`
- Create: `/Users/etanheyman/Gits/orchestrator/docs.local/handoffs/2026-07-17-notch-w1-native-port-REPORT.md`
- Append: `/Users/etanheyman/Gits/orchestrator/collab/2026-07-17-voicelayer-notch-w1-w2.md`

**Step 1: Record verified implementation receipts**

Update the OpenSpec rows only from fresh evidence. Report exact head, diff, tests, isolated app lifecycle, visual matrix, and any no-touch exception.

**Step 2: Review before publication**

Run the repository's bounded local review path, inspect the entire diff, and resolve critical/major findings through tests. Do not commit or push without Etan's explicit authorization.

**Step 3: Keep the resident gate closed**

No `/Applications/VoiceBar.app` swap occurs during development proof. A resident swap is allowed only via the release gate, followed immediately by Etan's F5 batch comparison against `resident-stable-20260717`.

**Step 4: Post the completion marker**

The implementation report/contract entry ends with:

```text
NOTCH_W1_NATIVE_PORT_READY_FOR_RELEASE_GATE
```
