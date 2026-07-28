# Long `voice_ask` guard design

## Problem

`voice_ask` speaks its entire message before opening the microphone and blocks
the caller throughout playback and response capture. A 2,256-character incident
produced roughly three minutes of speech. The VoiceBar teleprompter also hid the
prompt because TTS producers truncated display text to 2,000 characters before
the socket's byte-safe serializer could fit the frame.

## Design

Teach callers in the `voice_ask` tool description that the tool is for a short
question. Long content the user must understand or respond to must be split into
two or more sequential `voice_ask` calls. Each ask is an acknowledgement
checkpoint: wait for the user to confirm they absorbed one part before speaking
the next. `voice_speak` is only for announcements or status updates that do not
need a response. Include the measured scale warning that about 2,300 characters
takes about three minutes to speak before recording begins.

Reject messages longer than 1,200 characters before session booking, synthesis,
or playback. The refusal reports the actual character count, threshold,
estimated speech duration, and the same sequential acknowledgement-checkpoint
routing. Journal the refusal with caller, length, threshold, and duration.

The 1,200-character threshold is a backstop rather than the primary mechanism.
Across 204 recorded asks, p95 was 1,000 characters; 1,200 would reject 6/204
(2.9%) while still catching the 2,256-character incident. An 800-character
threshold would reject 31/204 (15.2%) and invert the description-first policy.

Remove both producer-side 2,000-character display slices in `src/tts.ts`.
VoiceBar's socket serializer remains the transport boundary: it preserves a
roughly 2,300-character frame when it fits and byte-safely truncates a roughly
10,000-character frame to the 8,191-byte ceiling.

## Testing

Use test-driven development:

- prove a message above 1,200 characters is refused with actionable routing and
  journal metadata before TTS;
- prove a normal message still reaches the existing voice flow;
- prove the schema description teaches the intended routing and scale;
- prove edge and cloned TTS paths pass the full 2,300-character display text;
- prove 2,300- and 10,000-character speaking events serialize safely, with only
  the oversized frame fitted by the socket layer;
- after GREEN, revert the production changes and rerun the regression tests to
  prove they return to RED, then restore and rerun GREEN.

Escape-to-stop playback remains out of scope.

`voice_speak` rewind and acknowledgement gating are also out of scope. They are
recorded as separate gaps because changing `voice_speak` behavior here would
expand this PR beyond the long-ask guard.
