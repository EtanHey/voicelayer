# Notch Launcher and Waveform Polish Design

## Goal

Restore Etan's approved launcher-management placement and eliminate the current clipping/spacing/fade regressions without changing VoiceLayer's W2 truth or waveform formulas.

## Approved state contract

- Hidden idle draws no software wing content.
- Idle-hovered launcher draws the microphone on the leading wing and History plus Dictionary on the trailing wing.
- Recording, transcribing, speaking, teleprompter/read-back, and post-speak never draw History or Dictionary.
- Recording, transcribing, and speaking reuse the same trailing-wing waveform identity. W2's seven-bar gold renderer, amplitude truth, archive/socket behavior, and live status truth remain unchanged.
- Every waveform gets a non-compressible 46×24 pt viewport. Transcribing must render all seven horizontal slots in at least 95% of captured frames. Speaking is the healthy reference; recording keeps the accepted W2 truth and gold mapping unchanged.
- Compact content is core-aligned and begins 13.5 pt beyond the physical bezel on both sides. Content-fit wings leave the spinner 14 pt from its outer edge while keeping the spinner/waveform core-padding delta at the ≤2 pt gate instead of the live 1.5-vs-13.5 pt failure.
- The current 8.5 pt hardware calibration stays. Framebuffer pixels under the physical housing are not visible: the codified 16 pt black-to-glass seam is translated fully outward beyond that swallowed region. The operator supplies the hardware and matching framebuffer fixtures through `VOICEBAR_NOTCH_HARDWARE_REFERENCE` and `VOICEBAR_NOTCH_FRAMEBUFFER_REFERENCE`; operator/phone evidence is authoritative for the bezel boundary.
- Compact controls keep replay/cancel/launcher actions bare, while stop is the deliberate contained destructive exception: a centered 8 pt square in a 20 pt red circle. Optical sizing is centralized.
- Every compact state uses the same 13.5 pt visible core gutter and one core-facing slot-layout rule. State-specific wing width may fit different content, but the material seam and slot alignment do not change by state.
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
- Frame/pixel census over recording→transcribing and transcribing→speaking entries: seven transcribing slots in ≥95% of frames, no shared bottom floor after the mode transition, and pixel-identical slot geometry across all three states. Recording gain is neither regraded nor changed in Round-2D.
- Actual-notch Dark/Light capture graded for a bilateral fade wholly outside the bezel, ≤2 pt spinner/waveform padding delta, management-button placement, primary-label parity, and existing contrast/birthmark gates.
- Repeat the 12-state gallery only after its scale receipt passes and its same-frame native reference has a ≥80 edge gradient; then grade every compact state against the 2× relative sharpness limit. A uniformly soft frame fails even when its ratio looks acceptable.
- Full Swift/Bun suites, corpus runtime gates, exact-head notarized app, then PR and lead-owned resident swap.

The direct Round-2C placement/clipping/fade directives constitute approval for this design; no additional aesthetic choice is introduced.

## Approved Round-2D convergence amendments

- Bank the 2c wins: seven transcribing bars, one-pixel live sharpness, and corrected compact-glyph contrast are regression fences, not code to revisit.
- On the calibrated built-in display, compact content begins about 13.5 pt beyond the physical bezel on both sides. The compact slot aligns toward the hardware core so spare wing width can never accumulate between content and the notch. Teleprompter geometry remains unchanged.
- The 8.5 pt hardware-width calibration stays. Compact fade placement starts at the calibrated physical-core edge; the old additional occlusion offset must not be counted again in either compact content padding or compact wing width.
- Compact recording and transcribing wings fit their mounted controls. A no-hold recording trailing wing reserves exactly one 46 pt waveform, two 20 pt controls, their 6 pt gaps, and the shared insets; VAD adds exactly one hold-control slot. Transcribing reserves one waveform plus one cancel control. No transparent tail may reveal a menu-bar glyph as a ghost control.
- Stop remains a 20 pt circular destructive control with its 8 pt square optically centered. The earlier bare-square interpretation is superseded.
- Every compact transient/status string uses the same live AppKit primary-label color as compact glyphs. This includes the double-tap hint and model-load/status strings in both appearances without relaunch.
- Recording amplitude, phase selection, W2 truth, and the 5beaf34 gold constants are frozen. Etan confirmed the red waveform was correct and quiet because he spoke quietly.
- The final blue-processing diagnosis is a one-time recording-to-transcribing anchor settle, not progressive drift: after the transition all seven bar bottoms lock to one floor while their tops keep moving. Each bar must occupy a fixed full-height, center-aligned slot, and the pixel census rejects a shared bottom floor without changing any waveform formula.

The Round-2D dispatch and corrections are the approval for these bounded amendments.
