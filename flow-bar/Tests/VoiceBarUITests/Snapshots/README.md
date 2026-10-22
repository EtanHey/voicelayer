# VoiceBar synthetic snapshots

Run `scripts/voicebar-snapshots.sh` from the repository. It renders 16 states in
light and dark appearance, compares PNGs, and writes an expected/actual/diff HTML
gallery to `.build.noindex/snapshots/index.html`. Only `--record` replaces references.
Review the gallery and reference diff before accepting an update; recording a frame
does not constitute approval.

References were generated on the MBP (Apple M4 Max). The script and pre-push gate
select that renderer; the M1 and hosted CI are excluded because their rendering is
not comparable. The XCTest catalog additionally requires `VOICEBAR_SNAPSHOTS=1`
and skips on GitHub Actions. Ordinary test runs still exercise the diff tolerance.
The local pre-push hook invokes comparison after its existing regression gate.

Each RGBA channel tolerates 16/255; at most 0.1% of pixels may exceed that threshold.
Dimensions must match exactly. Decorative waveform and spinner time is frozen via
a SwiftUI environment value whose production default uses the ordinary clock.
Rendering uses offscreen nonactivating fixture panels, synthetic text, empty
history loaders, no-op persistence and no-op command transport. It never starts
the installed app or accesses mic/audio.

States: idle, recording PTT, recording VAD, transcribing, speaking, paused,
teleprompter expanded/collapsed, queue +1/+10 with Next, last item without Next,
paused compact controls, hidden, snoozed, busy note, and Typed outcome.
Hidden/snoozed frames model the panel being ordered out by omitting BarView; they
verify the catalog's wallpaper-only expectation, not native window lifecycle.

These screenshots do not replace native click, focus, or audio acceptance gates.
Initial references require the lead's visual review before being treated as approved.
