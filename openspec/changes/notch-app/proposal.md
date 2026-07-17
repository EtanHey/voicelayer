# Change: VoiceBar notch-app revival

> **THROWAWAY — analyzer test-drive scaffold, now carrying verified W1 rows.** This change folder originated in the 2026-07-16 night build to exercise the openspec analyzer against a real spec section. It is NOT build authority: implementation works against ratified L1 §10 (`orchestrator/standards/layers/voicelayer.md`, PR #89 MERGED) and the completed pre-lane sweep report (`docs.local/research/notch-prelane-2026-07-16/SWEEP-REPORT.md`).

## Why

Etan's voice-round vision (verbatim-class, 2026-07-16): VoiceBar becomes a **high-UX notch app** — expandable teleprompter that PERSISTS and scrolls after turns, dynamic-island-class interactions. L1 §10 is the sanctioned change-path for the otherwise-frozen F5/pill surface: the freeze yields to Etan's explicit ask, and this is it.

Requirements base = the measured voice-QA gap ledger (L1 §8.9–8.13 + GAPS B12–B15): teleprompter closes at turn-end with no read-back; silence auto-close ends turns too eagerly; waveforms are static/unwired or amplitude-pinned; bottom-start jump-scroll recurs; ask→response gaps of 11–56s (median ~25s) are completely unsignaled.

## What Changes

- Teleprompter persist/expand + read-back after turns (§8.11) — keeps the original display script and scroll state available in truthful idle until permanent dismissal or a new recording/speaking turn.
- VAD-only HOLD-RECORDING control (§8.12) — suppresses both pre-speech and post-speech silence auto-close while selected, then starts a fresh full countdown on release; explicit stop/cancel and the overall safety timeout remain authoritative.
- Waveform parity across agent/user/listening turns — live amplitude, one render variant (§8.10).
- Bottom-start jump-scroll + answer-tail spoiler-flash + snap-to-top fixture family fixed (§8.9).
- Default-voice latency instrumented (TTFA: queue/synth/transfer) THEN fixed; dead-air gets a generating/thinking state (§8.13 + B15).
- Two-channel display law (§2) and live-teleprompter pace-correct sync (§8.8) apply in full.
- Operator-approved unified-glass native shell — fixed measured hardware core, content-fit side wings for hover/recording, one centered frameless teleprompter surface, shared material/fade/motion contracts, and shape-aware interaction around the physical notch. The approved React mock is the pixel authority; the native port starts only after W2's combined waveform head merges.

## Non-Goals (unchanged from L1 §10)

- No narration/dashboard teleprompters absorbed (L2/L3).
- No clone-voice synthesis back into L1 (D2 lock).
- The F5/dictation MECHANISM stays sacred even as its chrome is rebuilt (two-tier stability contract).

## Impact

- Affected specs: `voicebar-notch` (new capability).
- Affected code: new notch presentation/material/geometry types under `flow-bar/Sources/VoiceBarUI/`; thin integration touches in `BarView.swift`, `VoiceBarPresentation.swift`, `VoiceBarPanelLayout.swift`, `FloatingPanel.swift`, and `VoiceBarApp.swift`; and the TypeScript socket/input layer under `src/` for the independently tracked non-visual rows.
- Verification contract binds: F5 self-verify law (A4), corpus replay, engine disclosure, mic-state rule (L1 §7), two-channel original-display text, and isolated-app visual receipts.
