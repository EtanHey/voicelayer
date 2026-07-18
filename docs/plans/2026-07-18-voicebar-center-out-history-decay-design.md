# VoiceBar Center-Out History and Processing Pulse Design

**Status:** Approved by the 2026-07-18 Round-3B dispatch.

## Problem

The recording source already supplies seven real 50 ms RMS samples, but
`BarView` selects `organicAudioLevels`. That renderer keeps only the latest
sample, rebuilds every bar from one magnitude, and applies one uniform 0.18
second release. The result loses truthful per-bar shape and dies in unison.

The processing renderer is mirror-symmetric, but its distance-based phase shift
puts center and edge bars nearly out of phase. Symmetry alone therefore does
not prevent the rejected side-to-side/traveling read.

## Considered approaches

1. **Dedicated center-out history mapping — selected.** Keep all seven real
   samples, place the newest at the center, then place progressively older
   samples on alternating left/right rings. Apply the existing center weight
   after remapping. This preserves distinct time slices without reinstating a
   chronological left-to-right sweep.
2. **Use the existing independent mapping unchanged.** This is smaller, but it
   maps chronological samples across adjacent bars and recreates the rejected
   traveling-wave class.
3. **Mirror each time slice across both wings.** This reads center-out, but it
   duplicates samples, violates the seven-distinct-slice requirement, and
   restores rigid bilateral symmetry.

## Selected renderer contract

- Add a recording-specific render mapping. For seven bars, sample age travels
  through bar indices `[3, 2, 4, 1, 5, 0, 6]`: newest at center, then older
  samples radiate outward across both wings.
- Start from the existing clamped/padded `normalizedLevels` output, then apply
  `centerWeight` to each remapped sample. No per-clip normalization or
  synthetic motion is introduced.
- Only the recording call site uses this mapping. Speaking retains the
  accepted `organicReactive` presentation and its real playback envelope.
- Recording bars use the existing per-bar `transitionDuration`. Attack spans
  0.10–0.15 seconds; release spans 0.18–0.40 seconds with the existing stagger
  permutation and `easeOut`.
- Processing uses one shared temporal pulse multiplied by `centerWeight`.
  Every bar rises and falls in phase, while the spatial profile remains
  center-out and animated.

## Fences

- Do not change `VoiceState`, `PlaybackAmplitude`,
  `WaveformEnvelopeHistory`, TypeScript ask handlers, the -50 dBFS recording
  floor, or the fixed RMS mapping.
- Do not change `Theme`, panel layout metrics, or Round-3 padding tests.
- Do not route chronological history left-to-right.

## Permanent gates

- All seven real samples remain independently observable after center weighting.
- One-hot sample ages move through `[3, 2, 4, 1, 5, 0, 6]`, proving
  nondecreasing distance from center and no chronological adjacent sweep.
- All-zero history stays exactly flat.
- Recording attack and release use the required staggered bounds.
- Processing stays symmetric, center-dominant, animated, and in phase across
  sampled frames.

