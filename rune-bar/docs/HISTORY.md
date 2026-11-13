# History test host

Run from `rune-bar/`: `cargo test --locked`, then `cargo run --locked --bin history`.
The latter opens a native test window; headless proof uses `--snap`, `--script`,
`--frames`, and `--tree` instead. No backend or installed app is involved.

Use `VOICELAYER_RUNE_FIXTURE=1` for any public artifact or tree dump. The committed
fixture contains exactly 30 invented dictations, 25 asks and 22 speech entries.
`VOICELAYER_RUNE_HISTORY_CATEGORY=0|1|2` selects the initial category.
`python3 docs/scripts/history-pictures.py --proof-dir DIR` renders fixture pictures, a 60-frame
badge sequence; private runtime pictures require --private-out DIR.
Never dump the element tree or trace when reading the real archive.

Runtime scans `~/.local/share/voicelayer/recordings/YYYY-MM-DD/<entry>/` read-only.
Swift's Settings loaders have no root environment override. Dictations read
`audio.wav` existence, `metadata.json` and `voicelayer-transcript.txt`. Ask entries
have source `voice_ask` and additionally read `agent-transcript.txt`. Speech source
`speak`, schema 1 and matching directory ID read `speech.generated` in metadata,
falling back to `spoken.txt`. No audio file is opened. Symlink files/directories are
excluded. Unlike the Swift Speech index, this scan never creates a checkpoint or
index. Missing/malformed metadata is tolerated for recordings with audio; missing text uses a reason or placeholder.

The selector uses rune-kit; virtual rows bound mounting. Expanded text keeps a natural
height row in one stable virtual run. Buttons and context menus emit intent verbs
with category and local row ordinal only: no text, real IDs, paths or timestamps.
There are no clipboard, playback, paste or retranscription effects. The footer
pull activates only at the last loaded row, retains one matched element key, and
emits `intent open-settings` only at the full pull threshold. A cancelled gesture
never emits an intent. Escape collapses through the host's unhandled-key hook.

Proof is headless only. Live VoiceOver, trackpad physics and installed-app behavior
are unverified. Horizontal drags move the active page with the pointer and spring
back after selecting; adjacent pages are not pre-rendered during that drag.

Rune intentionally reads Dictations from the complete recordings archive, like Swift
Settings History, rather than the Swift notch's 20-item in-memory recent list.
Every kept recording with audio remains available, including bad or absent metadata;
missing transcripts use Settings History's reason labels. Ask leads with the trimmed
response and reveals the trimmed question on expansion. Speech omits unknown
durations, falls back to audio.duration_ms, and displays non-completed status/errors.

Ordering currently uses the raw created_at string and directory ID as a tie breaker.
It matches uniform UTC timestamps; mixed offsets/formats can differ from Swift's
day-key and parsed-date ordering. This remains a known limitation. Swift Speech's
day-prefixed validID rule is also deferred (P3-5). Load older reveals the next 20
entries from the launch scan, rather than rescanning the archive.

Pictures require an explicit destination:
python3 docs/scripts/history-pictures.py --proof-dir DIR
Real archive rendering additionally requires --private-out DIR; it produces no text
or tree output. Films use 60 badge frames and 20 expansion frames at 30 fps.
