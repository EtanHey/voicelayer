# VoiceBar synthetic snapshots

Run `scripts/voicebar-snapshots.sh` from the repository. It renders 17 states in
light and dark appearance, compares PNGs, and writes an expected/actual/diff HTML
gallery to `.build.noindex/snapshots/index.html`. Only `--record` replaces references.
Review the gallery and reference diff before accepting an update; recording a frame
does not constitute approval.

References were generated on the MBP (Apple M4 Max, Mac16,5). OS build,
host model and backing scale are recorded in environment.json. Any renderer
mismatch emits a specific expected/actual XCTSkip, without blocking a push.
References were re-recorded on 2026-11-05 after lane A commit `9df635663`
raised the intentional note text limit from 72 to 80 pt. The canvas reserves two
such limits, so compact/expanded captures grew by 16 px (259 to 275 / 455 to
471). References were stale since lane A, not environmental. The previous
reference-generation commit `f7ec1dc7f` still reproduces all 24 old PNGs byte for
byte on this host; changing only its limit from 72 to 80 reproduces the drift.
`environment.json` was regenerated and remains byte-identical: macOS 27.0 build
26A428, Mac16,5. Pixel thresholds and renderer mismatch skips are unchanged.

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
paused compact controls, hidden, snoozed, busy note, Typed outcome, and the 2.3 setup error
(the badged gear).
Hidden/snoozed frames model the panel being ordered out by omitting BarView; they
verify the catalog's wallpaper-only expectation, not native window lifecycle.

These screenshots do not replace native click, focus, or audio acceptance gates.
Initial references require the lead's visual review before being treated as approved.
