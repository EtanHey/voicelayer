# Teleprompter seek UI reference

These native NSHostingView/NSWindow snapshots use synthetic speaking events with realistic agent replies. No private utterances or recordings are included. Regenerate with:

```sh
VOICEBAR_REGENERATE_VISUAL_ARTIFACTS=1 swift test --package-path flow-bar --filter TeleprompterScrubTests.testWritesSpeakingLongReadAndCloneArtifacts
```

The harness writes the source snapshots to `docs.local/teleprompter-scrub/r2-*.png`.

- [Timed speech](speaking.png): real-timing buttons, current-word tint, shared adjustable scrub row.
- [Growing long read](long-read.png): playhead knob on the synthesized range, explicit "so far…" duration, dashed unknown remainder. The reserved dashed area is not an estimated total.
- [Clone without word timing](clone.png): uniform static dim track, matching row gutters, no knob, progress fill, word buttons or precise highlight. The caption explains the limitation.

Timed words alone get a pointer cursor, quiet hover tint, underline and a seek tooltip. Cursor push/pop is balanced across word transitions and view disappearance. A drag previews a time tooltip, enlarges the knob and sends one seek on release.

Playback preparation stays static and disabled until a positive duration arrives. Seeking uses the server's global timestamps once; a receipt restarts highlighting and scroll from the playback clock. No recording/capture/F5 mechanics change.

VoiceBar retains Replay, Show/Hide teleprompter and Stop. This differs from notch-v9's pause-centered transport because the daemon has no pause feature. The eye already has its Show/Hide tooltip. The top-right bars are the existing decoded audio-level indicator.

The snapshots prove fixture presentation, not installed-app audio seeking, macOS permission behavior or VoiceOver acceptance. Those remain separate release/installed checks.
