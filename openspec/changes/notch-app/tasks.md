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
- [ ] 3.8 Hardware-width propagation — replace the fixed hardware-path 185-point core with `housingFrame.width` in the shared panel/shape geometry; keep 185 only for flat displays and log the runtime value (Etan's current built-in probe: 185.0 pt).
- [ ] 3.9 Static birthmark gate — isolate the wing shadow to the material shape (never the clipped icon/waveform composite), reject any connected bottom-wing blob above the annotated +18/150-Retina-pixel threshold, and require settled contrast below +10.
- [ ] 3.10 Hover-hysteresis + idle-hold stability gate — exact-path entry; tight 12-point larger collapse-out zone; Etan-ruled cancellable 2.5-second exit grace; core→wing-icon→core never collapses. Require zero expanded-surface visibility toggles over a three-second/60-fps hold plus frame-matched cursor telemetry proving the cursor was outside throughout; a cursor-absent toggle remains a separate state-driven bug to root-cause.
- [ ] 3.11 Visible-surface singleton — isolated sockets remain transport-safe but may not create a second operator-visible VoiceBar; a new canonical or QA surface defers to the incumbent unless the explicit test-only parallel override is set.
- [ ] 3.12 Release gate — no resident swap until isolated proof passes; then Etan F5-batch comparison against `resident-stable-20260717`
- [x] 3.13 Round-3 animation readiness — compact wings, fixed hardware core, and lower surface remain separate positionable elements so wings can later slide from behind the island without structural rework; no Round-3 animation is implemented in this PR.
- [x] 3.14 Rendered wing-content sharpness gate — compare glyph-only wing and adjacent menu-bar regions in the same lossless capture, fail closed above a 2.0× reference-to-wing edge-gradient ratio, and require both wings in recording and transcribing. The isolated `6ac76a0` baseline failed at 14.06–103.53×; the Round-2C candidate passes at 1.57–1.82×.

Analyzer rider: no analyzer executable exists in this repository. This lane updated the scaffold rows directly and did not hunt for a runner; Round 2 ports only the two numeric recipes from the supplied external `docs.local/qa/notch-round1-2026-07-19/analyze.py` artifact into the checked-in capture verifier.
