# VoiceBar Pill Content-Hugging Geometry Design

## Approved scope

Round 3 changes compact pill geometry only. Waveform motion at `5b3f0d3` is accepted and remains byte-for-byte untouched. Teleprompter and queue envelopes keep their purposeful fixed viewports.

## Root cause

`Theme.pillContentWidth` returns a fixed `154` points for every recording state, even though VAD/ask recording adds a third action button. `BarView` compensates by changing horizontal padding from `14` to `5` points and content spacing from `8` to `4`, so the same red dot lands at different insets depending on entry mode. Transcribing uses a `212`-point minimum plus an estimated `textWidth + 96`, so the fixed outer frame can retain unused space on the trailing edge.

## Alternatives considered

1. Keep fixed state widths and tune separate ask/manual padding. Rejected because it preserves the source of the inconsistency and will drift again when controls change.
2. Measure a complete off-screen `BarView` on every state change. Rejected because the AppKit panel already consumes a deterministic layout model; feeding SwiftUI fitting size back into that resize loop adds lifecycle and animation risk.
3. Selected: derive compact recording/transcribing widths from visible component metrics in one shared model. The model owns the horizontal inset and inter-component spacing used by both `BarView` and `VoiceBarPanelLayout`. Recording grows only when the VAD hold button exists. Transcribing measures the visible label and reserves exactly the waveform, label gap, cancel button, and symmetric edge insets.

## Geometry contract

- Recording red-dot inset: `10` points for ask/VAD, F5/PTT, and pill-press/manual entry.
- Recording content spacing: `8` points for all entry modes.
- Recording width: indicator + waveform + two action buttons, plus one button and its internal gap only when VAD hold is visible.
- Transcribing width: waveform + optional measured status label + cancel button + declared gaps and symmetric `10`-point edge insets, clamped only by the existing compact minimum and panel maximum.
- No mode-specific compression is allowed to fit extra controls into a fixed recording width.

## Test and safety contract

- RED layout tests pin identical recording leading insets across hold/no-hold modes, content-derived width expansion, and transcribing width without residual trailing slack.
- Existing clickability tests remain green so controls keep their hit targets.
- `WaveformView.swift` and `WaveformViewTests.swift` hashes are recorded before and after the pass.
- Full Swift/Bun/typecheck checks and the isolated corpus verifier run on the committed head. The resident app is never touched.
