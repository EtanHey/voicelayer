# VoiceBar Notch V10 Material-Seam Refinement Design

**Status:** APPROVED. Etan accepted the native direction and explicitly asked why the hardware core does not visibly fade into the glass.

## Problem

The compact wing seam reserves the approved 16 points, but its core-side stop is only 82% black. Against the physical housing that produces a visible material cut instead of a continuous black-to-glass transition. The teleprompter surface has no corresponding seam veil at all. Its current mask is also assembled from three touching subpaths, so the shared material modifier strokes internal joins and can read as a gap between the top wings and lower body.

## Selected treatment

Keep the physical 185×32 core fixed and fully black. Inside each glass wing, draw a mirrored nonlinear 16-point veil whose core-side stop is 100% black and whose outer stop is transparent. Apply the same veil to compact and teleprompter states, above the material but below controls and the fixed core.

Replace the teleprompter's three touching subpaths with one concave outline: the path traces both top wings, the centered hardware cutout, and the lower body as one closed contour. The material and edge treatment therefore see one surface and cannot stroke an internal body/wing seam.

Hover geometry remains exactly as approved. Recording and compact-status wings receive a larger state-specific outer radius; no width, hardware position, hit region, motion order, or operational behavior changes.

## W2 boundary

This refinement is presentation-only. It consumes W2's `VoiceState`, `PlaybackAmplitudeEnvelope`, `recordingWaveformHistory`, socket/archive/timeout behavior, and the `WaveformView`/`BarView` renderer mapping as authoritative. It adds no waveform samples, smoothing, renderer, socket field, archive path, or lifetime state. Historical gate: #351 merged and #352 was rebased onto that merged main before #352 landed.

## Proof

- RED-first material tests pin a 100% black core stop, mirrored stops, and the 16-point width.
- RED-first shape tests pin a single teleprompter subpath and the centered hardware cutout.
- RED-first contract tests preserve the approved hover radius while requiring the rounder recording/status radius.
- Focused and full Swift suites remain green.
- Actual-notch Dark, Light, and Reduced Motion capture legs run ephemerally and terminate immediately after screenshots.
