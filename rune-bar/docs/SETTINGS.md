# Settings pilot

`cargo run --locked --bin settings -- --snap docs/pictures/settings.png` renders
without a native window. The default is the committed neutral snapshot, Dictionary
and History fixtures. `--real` reads only processing-settings.json,
whisper-performance.json and available voice-profile names beneath HOME; it never
reads dictionary or transcript archives. Those embedded lists are empty in this
mode. Unknown values say “Unavailable here”. No control writes its setting: each
prints an intent. Drawer geometry alone persists, in the worktree's ignored
`.build.noindex/settings-layout.json` (override `VOICELAYER_RUNE_SETTINGS_STATE`).

`SettingsSnapshot` documents each field's Swift source. `snapshot::read(home, env)`
has no writes. It keeps active recognizer facts separate from configured effort;
available clones do not establish selected speech profiles or clone daemon health.
A backend feed must fill the runtime values before this UI controls the live app.

The five tabs share a seven-stop pager: General, Transcription, Dictionary, Speech,
History/Dictations, History/Ask, History/Speech. Continuing past the ends wraps.
At History/Dictations, a rightward gesture returns to Speech. The axis is chosen
once per gesture. Dragging follows the pointer; release settles on Rune's REFLOW
spring. Reduce Motion switches without a slide. Keyboard arrows apply only while
the tab selector has focus. The whole bottom edge resizes, constrained to the
screen's visible frame; the configured headless screen height is injectable.

Dictionary and History use their existing view builders and tests, with generic
host traits routing handlers to the containing Settings state. Their standalone
binaries keep the original interactions; Settings suppresses their extra handles.

Run `cargo test --locked`. Generate the fixture pictures and films with
`python3 docs/scripts/settings-pictures.py <repository-local-proof-directory>`.
`SETTINGS_FILMS_ONLY=1` regenerates just the two films. This requires Pillow and
ffmpeg for inspection/encoding. The film canvas stays screen-sized while the
actual viewport grows and shrinks. No native, permissions, audio, clipboard or
real-agent proof is claimed by these headless artifacts.
