# Band replay

A separate `band` binary, sharing no Dictionary state. Replay-only: it cannot
connect to VoiceBar, record, play audio, type, or paste. Button presses print
intent JSON and retain it in view state; they do not execute commands.

From `rune-bar/` (put build output in this worktree's ignored `.build.noindex`):

```sh
CARGO_TARGET_DIR="$PWD/../.build.noindex/rune-target" cargo test --locked
CARGO_TARGET_DIR="$PWD/../.build.noindex/rune-target" cargo run --locked --bin band -- --replay docs/replays/band.ndjson --y-offset 60
../.build.noindex/rune-target/debug/band --replay docs/replays/band.ndjson --notch-width 185 --snap docs/pictures/band-recording.png --at 4.5 --scale 2
../.build.noindex/rune-target/debug/band --replay docs/replays/band.ndjson --notch-width 185 --frames 30 --fps 25 --start 6 --out ../docs.local/band-frames
```

The `t` field is the replay envelope's monotonic seconds; other fields use the
existing socket protocol. The reducer folds from the beginning on every sample,
so reverse seeks and separate runs produce the same state. Production socket
connection and incremental reduction are later slices. PTT exposes Pause;
the protocol has no separate locked-take event, so this slice uses `mode: ptt`.
The timer starts at the first audio-level event, retaining 0:00 during open.
A final transcription shows Typed for 1.2 seconds without displaying its text.

macOS reads NSScreen notch geometry. `--notch-width 0` forces the 48 pt pill.
`--reduce-motion` forces stationary cross-fading groups; the view also observes
the system preference. Geometry uses an analytically sampled Rune spring on
replay time; instantaneous subtree commits prevent a second layout easing from
making snapshot and native trajectories differ. Matched signal identities are
retained across the waveform/dot reparenting. The notch masks the travelling dots.
Once the final idle event has landed, no application wake timer remains.

Pictures are transparent 2x Rune renders. Native desktop captures and the movie
stay in the lead's private docs.local report folder. Native focus, physical
click-through, VoiceOver, other displays and installed integration are not
established by the headless assertions. During travel the dots cross the two
navigation glyphs on their way to the final spinner slot; review this overlap
in the video before accepting the motion design.
