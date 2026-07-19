# Notch Launcher and Waveform Polish Design

## Goal

Restore Etan's approved launcher-management placement and eliminate the current clipping/spacing/fade regressions without changing VoiceLayer's W2 truth or waveform formulas.

## Approved state contract

- Hidden idle draws no software wing content.
- Idle-hovered launcher draws the microphone on the leading wing and History plus Dictionary on the trailing wing.
- Recording, transcribing, speaking, teleprompter/read-back, and post-speak never draw History or Dictionary.
- Recording, transcribing, and speaking reuse the same trailing-wing waveform identity. W2's seven-bar gold renderer, amplitude truth, archive/socket behavior, and live status truth remain unchanged.
- Every waveform gets a non-compressible 46×24 pt viewport. Transcribing must render all seven horizontal slots in at least 95% of captured frames. Speaking is the healthy reference; recording must use its exact centered slot geometry and full-gain audio-driven mapping after speech detection.
- Compact content is screen-leading aligned. The spinner begins 14 pt from its wing edge and the waveform begins 16 pt beyond the physical bezel, keeping the measured padding delta at the ≤2 pt gate instead of the live 1.5-vs-13.5 pt failure.
- The current 8.5 pt hardware calibration stays. Framebuffer pixels under the physical housing are not visible: the codified 16 pt black-to-glass seam is translated fully outward beyond that swallowed region. Acceptance uses `/Users/etanheyman/Downloads/IMG_2908.JPG` against `/Users/etanheyman/Desktop/Screenshot 2026-07-19 at 23.23.07.png`, with operator/phone evidence authoritative for the bezel boundary.
- Compact controls use one bare-glyph language. Destructive and selected actions communicate through color rather than mixing filled controls with bare replay/hide glyphs; optical sizing and the stop glyph's slight down-right correction are centralized.
- Every compact state uses the same 16 pt visible core gutter and one screen-leading slot-layout rule. State-specific wing width may fit different content, but the material seam and slot alignment do not change by state.
- Compact wing glyphs use the current appearance's primary-label color, not the glass tint polarity. The permanent Dark/Light leg compares glyph-vs-glass contrast with native menu-bar glyph contrast from the same frame after a live appearance toggle.
- The historical state-gallery smear is not product evidence. A capture is admissible only after the app reports matching screen/window/root/all-descendant backing scales and the same frame contains a native menu glyph with a genuinely sharp edge. The app stays hidden until the first scale-correct render; screen/backing changes force rerasterization.
- The collapsed idle state remains genuinely absent: no glass, software core, or tint is painted. The light band in the historical `01-idle-bare` screenshot is the screen-capture representation of the menu bar behind the physical housing, not a VoiceBar surface.

## Alternatives considered

1. Reduce the waveform bar count. Rejected because Etan's acceptance test requires all seven bars and W2's renderer is the accepted shared component.
2. Keep the redundant default “Transcribing…” label. Rejected because the census shows it displaces the active cluster and the spinner already communicates the state. Exceptional model-loading status remains truth-layer state, but the compact wing does not duplicate it.
3. Reserve a fixed waveform viewport and correct wing sizing/insets. Selected because it fixes the shared horizontal and vertical clipping mechanism while preserving renderer truth.

## Verification

- RED/GREEN state-role and clickability tests for launcher-only History/Dictionary.
- RED/GREEN geometry tests for compact outer inset, 16 pt seam, and full waveform viewport.
- Frame/pixel census over recording→transcribing and transcribing→speaking entries: seven transcribing slots in ≥95% of frames; recording speech peaks reach at least 80% of speaking's range with symmetric center anchoring; all three slots are pixel-identical.
- Actual-notch Dark/Light capture graded for a bilateral fade wholly outside the bezel, ≤2 pt spinner/waveform padding delta, management-button placement, primary-label parity, and existing contrast/birthmark gates.
- Repeat the 12-state gallery only after its scale receipt passes and its same-frame native reference has a ≥80 edge gradient; then grade every compact state against the 2× relative sharpness limit. A uniformly soft frame fails even when its ratio looks acceptable.
- Full Swift/Bun suites, corpus runtime gates, exact-head notarized app, then PR and lead-owned resident swap.

The direct Round-2C placement/clipping/fade directives constitute approval for this design; no additional aesthetic choice is introduced.
