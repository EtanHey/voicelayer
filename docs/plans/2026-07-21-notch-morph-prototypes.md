# VoiceBar Notch Morph Prototypes — Implementation Plan

> Status: Implemented and in verification. Phase 1 #360 seam was posted before this round began. One branch, one app, three live-selectable variants, no merge.

## Task 1 — Pin prototype and selector contracts

Create `VoiceBarNotchMorphPrototype.swift` with the three variants, environment/default parsing, availability fallback, animation descriptors, native spacing, and bounded delight constants. Add RED tests for unknown values, P2 fallback, reduced motion, core translation zero, text-transform exclusion, and the 2–4%/≤4px/<350ms research limits.

Extend `PillContextMenuController` with a checkmarked `Morph Prototype` submenu and a selection callback. Add RED menu/controller tests before implementation.

## Task 2 — Wire one observable selection through the app

Create one selection model in `AppDelegate`, initialized from `VOICEBAR_NOTCH_MORPH_VARIANT` and the active defaults suite. Inject it into `BarView`/`VoiceBarNotchView`. Wire the context menu callback to update the same model so the next transition changes immediately without relaunching.

Keep default production behavior P1 in this prototype branch. The isolated capture harness sets an explicit variant.

## Task 3 — Implement P1 shared-shell morph

Add a private namespace to `VoiceBarNotchView`. Give compact and teleprompter hero branches the same `matchedGeometryEffect` ID with `.frame` properties and `.top` anchor. Apply the existing mass/stiffness/damping spring to presentation changes. Keep the idle mount boundary atomic and keep `fixedHardwareCore` outside the namespace with its nil-animation transaction.

Do not apply a distortion, blur, or bitmap scale to `notchSlots`.

Implementation note: a stable maximum canvas and explicit `VectorArithmetic` geometry were required in addition to matched geometry because AppKit panel resize/display commits otherwise collapse the transition into a hard cut. Teleprompter content is mounted only after the shell can contain it; closing stages content removal before geometry contraction.

## Task 4 — Implement P2 native glass identity experiment

Make `VoiceBarGlassContainer` variant-aware. On macOS 26, P2 wraps the shared host in `GlassEffectContainer(spacing:)` and applies one `glassEffectID`; pre-26 returns P1. Preserve the `NSGlassEffectView` material. Wrap its root in `NSGlassEffectContainerView` with the same spacing so native AppKit remains the pixel renderer.

Compile against the installed macOS 26 SDK and keep every symbol behind availability checks.

## Task 5 — Implement P3 bounded delight layer

Add a short triggerable edge/specular squash-settle modifier to the material shell only. Use at most 2.5% deformation and 4px equivalent overshoot, damping near 0.75, a 30–60ms accent beat, and total duration below 350ms. Reduced Motion disables it. The content slots and fixed core must not receive `scaleEffect`, `distortionEffect`, `layerEffect`, or blur.

## Task 6 — Add isolated dense transition capture

Add a script that launches one exact app on isolated sockets/defaults, selects P1/P2/P3 through the same runtime contract, drives compact↔teleprompter edges, and captures dense labelled frames against controlled busy and bright/black backdrops. Preserve video/probe receipts for cadence and independent full PNG sequences for visual/pixel truth; macOS video dirty-region encoding is not accepted as pixel evidence.

Run all variants from the same binary. Terminate each exact isolated PID in the trap. Do not touch `/Applications/VoiceBar.app`.

## Task 7 — Exact-head closeout

Run focused RED/GREEN suites, all Swift/Bun tests, typecheck, formatting/diff checks, corpus/runtime verification, Phase 1 readability/dismissal regression captures, and Phase 2 transition captures. Build one throwaway Developer-ID app with `--no-stop --no-relaunch`, require Apple notarization, and verify provenance/signing/staple/distribution.

Push the prototype branch and update PR #362 without merging. Post a Phase 2 collaboration seam listing how Etan selects each variant, exact receipts, known differences, and the lead-owned swap fence.
