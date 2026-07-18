# Native Notch Teleprompter Lifecycle Design

## Goal

Make the native notch teleprompter begin at the top, stay aligned with authoritative server timing for the full script, and retain read-back only while the pointer is using it.

## Approved behavior

- Live text paints from the top edge on its first frame. Word zero never starts vertically centered and then jumps.
- Exact one-to-one word boundaries remain unchanged.
- When pronunciation boundaries do not match display-token count, keep the original display text and resample its word schedule across the authoritative boundary start/end duration. Do not replace Etan's spelling with phonetic boundary text and do not use an unbounded per-word estimate that drifts from audio length.
- The speaking event is already emitted when playback actually starts, so the old unconditional 300 ms client delay is removed.
- Playback completion retains a static, scrollable read-back while hovered. If it appears unattended or the pointer leaves, dismiss it after an 800 ms grace window. Re-entry before expiry cancels dismissal.
- Explicit hide/show and dismiss controls remain available.

## Alternatives considered

1. **Boundary-duration resampling — selected.** Keeps exact display text, exact one-to-one timing when available, and the authoritative overall audio duration when phonetic tokenization differs.
2. **Globally scale the existing local word estimator.** Similar total-duration behavior but less explicit about the server schedule and easier to regress into local timing ownership.
3. **Render server boundary tokens directly.** Rejected because pronunciation tokens can replace original names and product spelling.

## Architecture

- `TeleprompterContentModel` owns display-token construction and derives a monotonic resampled schedule only for mismatched timed boundaries.
- `TeleprompterScrollPolicy` owns the top-first viewport contract.
- `TeleprompterPlaybackPolicy` owns the zero startup-delay contract.
- `VoiceBarNotchPresentationModel` owns the read-back hover grace task because it is the long-lived native presentation object. `BarView` supplies current read-back/hover state and the existing `VoiceState.dismissRetainedTeleprompter()` action.
- W2 truth remains untouched: no changes to `VoiceState`, `PlaybackAmplitude`, `WaveformEnvelopeHistory`, socket protocol, ask archive/timeout code, `WaveformView`, or renderer mapping.

## Tests

- Mismatched phonetic boundaries retain original display words and end on the server boundary endpoint.
- Resampled offsets are monotonic and exact one-to-one boundaries remain exact.
- Initial viewport alignment is top and playback startup delay is zero.
- Unattended read-back dismisses after the grace period.
- Hover cancels a scheduled dismissal; leaving schedules a fresh full grace period.
- Non-read-back states never schedule dismissal.

