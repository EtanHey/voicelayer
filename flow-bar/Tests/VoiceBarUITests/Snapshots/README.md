# VoiceBar synthetic snapshots

Run `scripts/voicebar-snapshots.sh` from the repository. It renders 16 states in
light and dark appearance, compares PNGs, and writes an expected/actual/diff HTML
gallery to `.build.noindex/snapshots/index.html`. Only `--record` replaces references.
Review the gallery and reference diff before accepting an update; recording a frame
does not constitute approval.

References were generated on the MBP (Apple M4 Max, Mac16,5). OS build,
host model and backing scale are recorded in environment.json. Any renderer
mismatch emits a specific expected/actual XCTSkip, without blocking a push.
The catalog runs inside the existing scripts/run_tests.sh Swift test phase,
under its heavy-suite gate and sharing its build. There is no extra hook step.
Standalone comparison uses the same default Swift build directory.

Each RGBA channel tolerates 16/255; at most 25 pixels may exceed that threshold.
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
