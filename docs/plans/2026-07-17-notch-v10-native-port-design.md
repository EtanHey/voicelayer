# VoiceBar Unified-Glass Native Port Design

**Status:** APPROVED FOR PLANNING ONLY. Etan approved the React target as “perfect.” Native implementation remains gated on W2's combined waveform repair + P0 head merging.

## Sources of truth

1. Pixel/interaction target: `site/components/notch-lab/hybrid/HybridNotchPrototype.tsx`, `contract.ts`, and `unified-glass.module.css`.
2. Approved intent: `docs/plans/2026-07-17-notch-v10-unified-glass-design.md`.
3. Native glass and physical-notch evidence: `2026-07-17-notch-w3-REPORT.md` and the actual-notch matrix it cites.
4. Polish bar: `docs.local/research/notch-prelane-2026-07-16/DESIGN-BAR.md` (DynamicLake/Clicky cleanliness; the mock remains the pixel authority).
5. Sequencing authority: `voicelayer-lead SEQUENCING RULING (2026-07-17 23:10 IDT)` in the W1/W2 contract.

## Approved contract translated to points

The React pixels map one-to-one to Swift points on the verified built-in display:

| Presentation | Core | Leading wing | Trailing wing | Top width | Lower body | Total height |
|---|---:|---:|---:|---:|---:|---:|
| Idle | 185 × 32 | 0 | 0 | 185 | 0 | 32 |
| Hover launcher | 185 × 32 | 36 | 64 | 285 | 0 | 32 |
| Recording | 185 × 32 | 72 | 152 | 409 | 0 | 32 |
| Teleprompter | 185 × 32 | 76 | 88 | 349 | 465 × 196 below the top row | 228 |

Teleprompter body extents are 140/140 around the centered core. Each teleprompter wing reserves a 16-point core-side black-to-glass fade, an 8-point fade-to-content gap, and 8 points of outer padding. That leaves 44 points of leading content and 56 points of trailing content. The inverse join radius is 5 points and the waveform slot remains 72 points where the operational content needs it.

The physical core width is measured from `NSScreen.auxiliaryTopLeftArea.maxX` to `NSScreen.auxiliaryTopRightArea.minX`; the accepted machine measures exactly 185 points. The pure contract tests use 185. Runtime positioning uses the measured housing edges, with 185 only as the documented fallback when auxiliary areas are unavailable.

## Architecture choice

### Considered approaches

1. **New notch shell with thin adapters — selected.** New value types own visual state, geometry, material, shape, motion, and hit regions. Existing operational state and controls enter through narrow adapters. This directly mirrors the mock contract and confines the W2 rebase mostly to `BarView.swift`.
2. **Rewrite the capsule in place.** Rework `BarView`, `Theme`, and `VoiceBarPanelLayout` directly. This creates fewer files, but mixes product state with glass geometry and maximizes conflict with W2's current `BarView` work.
3. **Add a second window/overlay for the glass.** Keep the pill and render wings/body separately. This weakens one-surface morphing, risks focus/hit-test drift, and creates synchronization problems between windows.

Approach 1 is the only option that preserves the approved one-object illusion while giving geometry, material, and transition logic pure test seams.

## New Swift types

All files below are new and therefore safe to prepare only after branching from the W2-merged main.

### `VoiceBarNotchContract.swift`

- `VoiceBarNotchVisualState`: `.idle`, `.hoverLauncher`, `.recording`, `.teleprompter`, plus a `.compactStatus` compatibility case for existing non-mock operational states such as transcribing/error/confirmation.
- `VoiceBarNotchGeometry`: core, wing, body, content-safe, inverse-radius, and total-size values.
- `VoiceBarNotchMaterialContract`: 16-point fade, 8-point gap, 8-point outer inset, one lower-surface layer, no inset frame, compact outer-edge treatment, and no core backdrop.
- `VoiceBarNotchMotionContract`: spring `stiffness=310`, `damping=31`, `mass=0.72`, `bounce=0`; panel delay `0.05s`; content exit `0.12s`.
- `VoiceBarNotchPresentation`: immutable adapter output containing visual state, geometry, content roles, and accessibility labels. It does not mutate `VoiceState`.

### `VoiceBarNotchScreenGeometry.swift`

- Resolves hardware housing edges from safe-area and auxiliary-top-area APIs.
- Produces the top-centered AppKit panel frame from `screen.frame`, not `visibleFrame`.
- Separates `.hardwareNotch` from `.flatDisplayFallback`; the physical-notch contract never fabricates a core width when real auxiliary areas exist.
- Recomputes through the existing display-parameter-change lifecycle.

### `VoiceBarNotchShape.swift`

- An animatable `Shape` for the single teleprompter glass surface: narrow 349-point top bar, curved 5-point inverse joins/shoulders, centered 465-point lower body, 18-point lower corners.
- Compact wings remain independent left/right shapes around the black core; they use the same material primitive and outer-edge treatment, not transparent border-only shells.
- The hardware core is a separate, fixed, opaque-black layer with no material modifier and no animated position.

### `VoiceBarNotchMaterial.swift`

- `VoiceBarGlassMaterial` applies the shared tint, backdrop sampling, highlight, inner shade, and outer shadow.
- macOS 26+: native SwiftUI glass. Use a `GlassEffectContainer` for the two compact siblings and direct glass for the one teleprompter body shape, matching the W3 topology ruling.
- macOS 14–25: `.ultraThinMaterial` in the same geometry with explicit tint/highlight/shadow overlays. An opaque fallback remains available for reduced-transparency/render failures.
- `VoiceBarBlackToGlassFade` draws the mirrored 16-point black-to-transparent seam inside each wing/body edge. It never blurs the core.

### `VoiceBarNotchMotion.swift`

- `VoiceBarNotchPhase`: `.settled`, `.opening`, `.closing`.
- `VoiceBarNotchTransitionPlan` encodes the approved hierarchy: open wings → body 50 ms later → content; close content over 120 ms → body → wings.
- Reduced Motion keeps the same ordering with short opacity transitions and no near-zero axis scaling.
- The fixed core is excluded from every animatable value.

### `VoiceBarNotchHitRegion.swift`

- Represents the visible union rather than one bounding rectangle: compact leading/core/trailing strips; teleprompter top bar plus lower body.
- Prevents transparent top corners of the 465-point teleprompter window from swallowing menu-bar clicks.
- Supplies `contains(_:)` to both hosting-view and panel event routing.

### `VoiceBarNotchPresentationModel.swift`

- View-local/AppKit-shared presentation state for hover, keyboard focus, reduced-motion preference, and transition phase.
- Notifies the panel layout owner when hover/focus changes without adding visual-only mutation to `VoiceState`.
- Keeps operational truth in `VoiceState`; no new socket or daemon state is introduced.

### `VoiceBarNotchView.swift`

- Composes the fixed core, leading/trailing `VoiceBarGlassWing`, optional continuous lower body, and typed content slots.
- Accepts existing controls/content as closures or small content values from `BarView`.
- Owns no recording, playback, hold, history, vocabulary, or teleprompter lifetime behavior.

## State mapping

`VoiceBarPresentation` remains the operational-to-presentation adapter. It will produce `VoiceBarNotchPresentation` using the following precedence:

1. A live or retained teleprompter envelope maps to `.teleprompter` even when operational mode is truthfully idle.
2. `.recording` maps to the approved recording wings and consumes W2's final `VoiceState.audioLevel -> WaveformView` seam unchanged.
3. Existing transcribing, error, disconnected, command, clip-marker, paste-confirmation, and queue states map to `.compactStatus` and retain their behavior inside the same fixed-core/wing architecture. They do not create a second capsule or lower panel.
4. Plain idle plus hover or keyboard focus maps to `.hoverLauncher`.
5. Plain idle without hover/focus maps to `.idle` and adds zero visible pixels beyond the hardware housing.

Hover acknowledges and exposes Mic/History/Dictionary; it does not open the teleprompter. Recording/speaking state remains authoritative for live expansion. A retained teleprompter remains an idle presentation overlay exactly as the existing W1 lifetime contract specifies.

## Data and interaction flow

```text
VoiceState + VoiceBarNotchPresentationModel
                    |
                    v
       VoiceBarPresentation adapter
                    |
                    v
       VoiceBarNotchPresentation
          | geometry/material/motion
          | content roles/actions
          v
          VoiceBarNotchView
          |          |          |
       leading     fixed      trailing/lower
        wing       core          content
                    |
                    v
 VoiceBarPanelLayout + VoiceBarNotchHitRegion
                    |
                    v
       FloatingPillPanel / AppKit frame
```

Mic routes to `BarCommandRouting.handlePrimaryTap()`. History and Dictionary reuse the current popovers. The mock's first recording-control position maps to the existing VAD-only HOLD control (`hand.raised` / `hand.raised.fill`); it is absent for PTT and does not introduce a new pause protocol. Stop and cancel reuse current router actions. The live waveform stays `WaveformView`; the teleprompter stays `TeleprompterView`. The shell changes placement and material, not those behaviors.

## Existing-file touch map after W2 merge

### Unavoidable

| File | Why it must change | Conflict policy |
|---|---|---|
| `flow-bar/Sources/VoiceBarUI/BarView.swift` | Replace capsule composition with `VoiceBarNotchView`; feed existing controls/teleprompter/waveform into typed slots. | Rebase onto W2's merged file first; preserve its transcribing release overlay and final waveform call sites. |
| `flow-bar/Sources/VoiceBarUI/VoiceBarPresentation.swift` | Add the pure operational-to-notch presentation adapter. | Presentation-only; no producer state. |
| `flow-bar/Sources/VoiceBarUI/VoiceBarPanelLayout.swift` | Return exact notch bounds and shape-aware hit regions from the new geometry. | Preserve existing paste/queue/teleprompter semantics through adapter tests. |
| `flow-bar/Sources/VoiceBarUI/FloatingPanel.swift` | Accept a point hit-test predicate/region instead of only one `CGRect`; select notch-specific level without changing nonactivation. | Keep init-time `.nonactivatingPanel` and focus behavior. |
| `flow-bar/Sources/VoiceBar/VoiceBarApp.swift` | Own the presentation model, pass it to view/layout, anchor from physical screen geometry, and reapply layout on hover/focus/display changes. | AppKit wiring only; no audio/socket changes. |
| `flow-bar/Tests/VoiceBarUITests/VoiceBarPresentationTests.swift` | Assert state precedence and compatibility mappings. | Update after W2 tests land. |
| `flow-bar/Tests/VoiceBarUITests/VoiceBarPanelLayoutTests.swift` | Assert 185/285/409/465×228 geometry and hit regions. | Replace obsolete capsule-width expectations intentionally. |
| `flow-bar/Tests/VoiceBarUITests/BarViewClickabilityTests.swift` | Re-target control coordinates/hit tests to wing and lower-body slots. | Preserve every existing action-routing assertion. |
| `flow-bar/Tests/VoiceBarUITests/BarViewSnapshotArtifactTests.swift` | Produce exact-state native pixel receipts for comparison with the approved mock. | Add, do not claim approval from automated render alone. |

### Explicitly no-touch unless the rebased W2 head exposes a compile-only seam

| File | Rule |
|---|---|
| `flow-bar/Sources/VoiceBarUI/VoiceState.swift` | No visual state, hover coordinator, geometry, or motion state is added. Consume W2's merged properties as-is. |
| `flow-bar/Sources/VoiceBarUI/WaveformView.swift` | No geometry/material changes. W1 supplies a fixed slot and consumes W2's final renderer unchanged. |
| `flow-bar/Sources/VoiceBarUI/TeleprompterView.swift` | No timeline/lifetime/material change. Mount the existing view inside the new lower-surface content slot. |
| `flow-bar/Sources/VoiceBarUI/Theme.swift` | Do not mix notch constants into legacy global tokens; all approved constants live in the new contract. |
| `src/` and daemon paths | No protocol, amplitude producer, recording-hold, or F5 mechanism changes. |

If an allegedly no-touch file becomes necessary after rebase, stop implementation at that diff, document the exact compile/behavior seam in the contract, and keep the change minimal. This is a rebase exception, not pre-authorized scope expansion.

## Verification design

- Pure contract tests lock every approved number, content-safe derivation, state precedence, transition ordering, and reduced-motion plan.
- Shape tests sample/path-bound the centered 349-to-465 teleprompter silhouette and assert one lower-surface layer.
- Screen tests cover the verified 185-point auxiliary-area fixture, unavailable-API fallback, and full-frame top anchoring.
- Hit tests prove transparent teleprompter corners are pass-through while all controls remain clickable.
- Existing hold, teleprompter lifetime, click routing, waveform truth, paste, and F5 suites stay green.
- Isolated native receipts cover idle, hover, recording, transcribing release, live teleprompter, retained read-back, Light/Dark, unfocused/nonactivating behavior, and Reduced Motion.
- Final human comparison is against the “perfect” React mock and the DynamicLake cleanliness bar around the actual hardware notch.

## Sequencing and release fences

1. This document and its companion implementation plan are paper only.
2. W2's combined repair + P0 head must merge before any Swift file above is created or modified.
3. Implementation starts from a fresh branch off that new main; never port by copying the current old-head native files.
4. Proof uses an isolated app and exact-PID cleanup. The resident `/Applications/VoiceBar.app` and daemon remain untouched.
5. Resident swap occurs only through the release gate, followed by Etan's F5 batch against `resident-stable-20260717`.
