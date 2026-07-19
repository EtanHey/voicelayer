# Tasks: notch-app

> **THROWAWAY analyzer test-drive scaffold.** Build authority remains L1 §10. W1 rows are updated here as a test-drive record; remaining rows are not dispatched by this lane.

## 1. Pre-lane

- [x] 1.1 Fold-first sources located + staged (`docs.local/research/notch-prelane-2026-07-16/sources/`)
- [x] 1.2 xhigh Codex Drive-verify sweep dispatched (still-valid/superseded/missing table)
- [x] 1.3 Sweep report reviewed and incorporated into the W1 implementation brief

## 2. Build phase

- [x] 2.1 Teleprompter persists + scrolls after turn-end (read-back) — retains original-script text/boundaries in truthful idle; reversible eye hide/show; permanent × dismissal; new-turn clear; static readable scroll view; idle-collapse suppression
- [x] 2.2 VAD-only HOLD-RECORDING control — accessible selected state; strict mirrored socket command; pre/post-speech silence suppression; fresh countdown on release; explicit stop/cancel and overall timeout unchanged
- [ ] 2.3 Waveform parity — RED fixture: agent-side dot row static across six turns (frame_0413 class)
- [ ] 2.4 Jump-scroll/spoiler-flash/snap-to-top family — fixtures qa a7_10–a7_14, frames 0642/0655
- [ ] 2.5 TTFA telemetry (queue/synth/transfer) + generating-state for dead-air — baseline 11–56s in hand
- [ ] 2.6 Two-channel display split in the live teleprompter — RED fixture: respelled name renders in display
- [ ] 2.7 Pace-correct sync fix (not offset-shift) — fixtures frames 0045/0048/0078 + silencedetect onsets

## 3. Operator-approved unified-glass native port

- [x] 3.1 React mock approved by Etan (“perfect”); approved geometry/material/motion contract frozen as the native pixel target
- [x] 3.2 Paper-only Swift architecture and TDD implementation plan written, including new-type boundaries and explicit W2 shared-file touch/no-touch map
- [x] 3.3 Sequencing gate — initial W1 branch was based on post-P0 `db90fcc`; #351 merged as `d721e11`, and W1 rebased onto that merged main with the first post-rebase exact-head gate at `0471cebe87f855a134df15195ad3c44feb07a3a7`
- [x] 3.4 New pure native contracts — visual-state reducer, measured-hardware core with a 185-point flat-display fallback, corrected 36/64 · 72/152 · 76/88-point wing extents, shared fade-safe insets, and motion hierarchy
- [x] 3.5 New shell primitives — safe-area/auxiliary-top-area-derived physical-notch placement with the 185-point fallback, one teleprompter shape, shared glass/fallback material, fixed black core, ordered motion, and shape-aware hit regions
- [x] 3.6 Rebase integration — adapted `VoiceBarPresentation`, `VoiceBarPanelLayout`, `BarView`, `FloatingPanel`, and `VoiceBarApp` over W2 while leaving `VoiceState`/`WaveformView`/`TeleprompterView` behavior unchanged
- [x] 3.7 Native verification — post-#351 gate rerun at `01b6289da4e9c7771826d00bcb2152ace3440023`: Swift `579/8 skipped/0 failed`, Bun `1371/2 skipped/0 failed`, typecheck, corpus `10/10`, F18/Escape/stop, and F5 finish-paste pass; isolated actual-notch Dark/Light/Reduced-Motion rehearsal receipts are under `docs.local/notch-v10-native-port/notch-20260719T014100Z/rehearsal-01b6289`; Round-1 verification pixel-samples the shipped Dark/Light PNG pairs and fails either appearance below WCAG `4.5:1` text or `3:1` control contrast. After the 2026-07-19 live-disruption correction, notch-w1 only builds/notarizes and posts the exact-head seam; `voicelayer-lead` alone swaps the operator surface and performs the same-process Dark→Light→Dark live-toggle receipt leg.
- [x] 3.8 Hardware-width propagation — measured `housingFrame.width` flows through shared panel/shape geometry, with an 8.5-point-per-side hardware calibration and 185 only for flat displays; the built-in probe reported 185.0 pt before calibration.
- [x] 3.9 Static birthmark gate — wing shadow is excluded from clipped glyph/waveform alpha; the verifier rejects connected bottom-wing blobs above the annotated +18/150-Retina-pixel threshold and fails closed on empty samples.
- [x] 3.10 Hover-hysteresis + idle-hold stability gate — tight expansion geometry, padded retention geometry, cancellable 2.5-second exit grace, core→wing-icon→core retention, and cursor-absent zero-toggle verification are implemented.
- [x] 3.11 Visible-surface singleton — noncanonical siblings are detected by bundle identity/process inspection, while an explicit QA-only parallel override remains available for isolated capture.
- [x] 3.12 Release gate — Round-2C was captured and notarized before the lead-owned swap; canonical notch release 2.1.16 (`ef4b73c`) was installed and post-deploy verified.
- [x] 3.13 Round-3 animation readiness — compact wings, fixed hardware core, and lower surface remain separate positionable elements so wings can later slide from behind the island without structural rework; no Round-3 animation is implemented in this PR.
- [ ] 3.14 Rendered wing-content sharpness gate — compare glyph-only wing and adjacent menu-bar regions in the same lossless capture, fail closed above a 2.0× reference-to-wing edge-gradient ratio, and require the native reference itself to meet the absolute 80-gradient sharpness floor. The prior gallery's `6ac76a0`/Round-2C ratios are VOID because both samples were captured through the soft harness; completion waits on a scale-receipted re-capture.
- [ ] 3.15 Compact gallery polish — source/TDD slice complete: idle-hover restores History + Dictionary and active flows exclude both; recording/transcribing/speaking reuse one fixed unclipped 46×24 seven-bar waveform slot; compact slots use a screen-leading 14/16 pt padding contract; controls use one bare-glyph language with centralized optical correction. Completion waits on the lead-owned exact-candidate re-capture and visual grade.
- [ ] 3.16 Pixel-true launch/capture preflight — the panel stays hidden until screen/window/root/all-descendant backing scales match; launch and screen/backing changes force rerasterization; the app emits a scale receipt; the verifier rejects a missing/mismatched receipt and any uniformly soft same-frame native reference.
- [ ] 3.17 Hardware-visible fade + appearance parity — retain the operator-verified 8.5 pt calibration, place the full 16 pt fade outside the physically occluded bezel region, and require current-appearance primary-label wing glyphs to meet same-frame native menu-glyph contrast in both live-toggled appearances.

Analyzer rider: no analyzer executable exists in this repository. This lane updated the scaffold rows directly and did not hunt for a runner; Round 2 ports only the two numeric recipes from the supplied external `docs.local/qa/notch-round1-2026-07-19/analyze.py` artifact into the checked-in capture verifier.
