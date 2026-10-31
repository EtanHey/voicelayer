# Speech settings (daemon core)

Personal pronunciations live only in
`~/.local/state/voicelayer/tts-pronunciations.json`, a JSON map of exact terms to
spoken text. `VOICELAYER_STATE_DIR` replaces the state directory, including in
tests. Nothing is seeded into this file or the bundled developer dictionary.
Use `voicelayer pronounce add --term TERM --say 'spoken text'`,
`voicelayer pronounce list`, and `voicelayer pronounce remove --term TERM`.
Writes are atomic with file mode `0600`. Concurrent edits return a busy error
before reading or changing the map; abandoned locks are never automatically
removed. Matching is case-sensitive and uses
whole words (including Unicode word boundaries); spoken values are literal.
The map is re-read at each pronunciation snapshot and joins the existing YAML
rule pipeline before Edge/clone synthesis, including long reads and fallback.
Missing/empty maps do nothing. Malformed maps are ignored for narration;
CLI edits report an error and preserve the file for repair. No per-read UI is
required. The legacy `~/.voicelayer/pronunciation.yaml` rules remain supported.

Both engine projections expand currency amounts (`₪180/h` becomes “one hundred
eighty shekels per hour”), numeric rates (`2.50/kg` becomes “two point five zero
per kilogram”), decimals and section numbers (`10.3` becomes “ten point three”).
Fractional digits are spoken individually. Existing filename rules produce
“reply draft dot M D” for `reply-draft.md`. Display text and source ranges stay
attached to the original text; fractions, times and dotted calendar dates stay
lexical.

Checked Markdown list items (`[x]` or `[X]`) end in `, done.`; unchecked
`[ ]` items remain plain. Raw Markdown projections keep the captured display
unchanged and represent completion as a zero-width display insertion, which
both timing adapters skip. Selection reads include `, done.` in their flattened
teleprompter text, so its displayed word receives its own measured timing.
Checkboxes inside backtick spans do not acquire completion speech.

The daemon re-reads `~/.local/state/voicelayer/tts-settings.json` on each speak.
`VOICELAYER_TTS_SETTINGS_PATH` overrides the location. Writes use a temporary
file and atomic rename, with `version: 1` and an ISO `updated_at` timestamp.
Only changed fields need to be stored:

```json
{
  "version": 1,
  "profiles": {
    "short": { "engine": "edge", "voice": "en-US-JennyNeural", "rate": "+0%" },
    "long": { "engine": "clone", "voice": "theo-c4s", "rate": "+10%" }
  },
  "short_limit_chars": 400
}
```

`voice_speak` uses SHORT. Internal callers can pass `profile: "long"` or
`profile: "auto"` to `speak`, or use the exported
`resolveSpeakProfile(kind, text)`. Auto selects LONG only above the character
limit. MCP caps remain 1200 characters for speaks and 600 for asks.

`QA_VOICE_TTS_VOICE` and `QA_VOICE_TTS_RATE`, when defined even as empty strings,
override and lock the corresponding fields in both profiles. A defined voice
also determines the engine from the installed profile inventory, overriding
any saved engine, and reports its engine source as environment. Empty values keep
the historical Jenny / +0% fallback. Explicit speak voice/rate arguments win.
An edge-profile file rate overrides the mode rate; absent that rate, the existing
mode rates, environment fallback, and edge long-text slowdown are preserved.
Clone-profile rates apply only to clone playback. Its short announcement shortcut
and synthesis fallback retain the legacy edge mode rate unless the caller
explicitly supplies a rate. Clone rates
use ffmpeg tempo adjustment without changing pitch; untouched clone playback
keeps its original speed. An unset engine retains legacy voice-based detection;
an explicitly selected engine routes to edge or the existing clone cascade.
Missing selected clone profiles log a warning and use the edge default.
Unavailable synthesis keeps the existing profile edge fallback. Callers requiring
a clone (option or QA_VOICE_TTS_REQUIRE_CLONE) remain fail closed in both cases.

Send a newline-delimited socket command, with an optional correlation id:

```json
{"cmd":"set_tts_setting","key":"long.rate","value":"+10%","id":"speech-1"}
```

Keys are `short.engine`, `short.voice`, `short.rate`, the matching `long.*` keys,
and `short_limit_chars`. Engines are `edge` / `clone`, rates are signed integer
percentages from -99% to +100%, and the limit is a positive safe integer.
Inconsistent effective engine/voice pairs are rejected before writing. To switch
both fields together, use the additive atomic form (rate and id are optional):

```json
{"cmd":"set_tts_setting","profile":"short","engine":"clone","voice":"theo-c4s","rate":"+10%","id":"speech-2"}
```

`profile` is `short` or `long`. Both engine and voice are required; omitting rate
preserves the saved rate. Atomic and dot-key forms cannot be mixed. Voices are
trimmed before persistence. Env-locked fields reject the whole transaction.
Changes apply to the next speak, including changes made during playback.
The ack contains fresh `tts_controls`; env-locked writes are rejected with
`Set by <VAR>`.

Health includes `tts_controls.profiles.short/long` with engine, voice, and rate
`{source, raw, effective}` objects, optional `locked` text, and nullable
`last_first_audio_ms`. It also includes the character-limit setting,
`available_voices` entries `{engine, voice}`, and `clone_daemon: "up" | "down"`.
Available voices include edge defaults, valid edge preset aliases from
`~/.voicelayer/voices.json`, and the accepted clone `theo-c4s` when its directory contains
`profile.yaml`. Theo variants and Huberman are excluded without deleting assets.
Ben (`ben-c1`, alias `ben`) appears only with an accepted, matching Qwen3 profile
and a nonempty reference transcript plus a nonempty regular WAV inside the voices
root, at most 5 MiB. Symlink escapes and missing assets are unavailable; a WAV and
TXT directory alone is insufficient. Readiness is refreshed on each catalog read.
No narrationlayer aliases are invented. A ready Ben selection survives relaunch;
when the clone daemon is down, the existing Fast fallback and its `(fallback)`
measurement label apply.

Clone health uses an authenticated, 500ms `/health` probe on localhost:8880,
coalesced and cached for five seconds. It never starts or loads a model. The
synchronous health snapshot starts a background refresh; its next poll observes
the result (initially down). Up requires `status: "ok"` and `model_loaded: true`.

Each successful player spawn logs one line:
`[tts] first_audio_ms=N profile=short engine=edge-tts voice=... chars=N`.
Latency includes synthesis and queue wait; rejected, disabled, failed, or
cancelled-before-playback requests do not replace the last successful value.
This core change does not supply a Swift settings screen or native acceptance.

VoiceBar Settings → Speech (also `voicebar://settings/speech`) presents separate
Short speaks and Long reads cards. Each shows one Voice picker grouped into Fast and Cloned,
rate, and the last first-audio latency. Selecting a voice writes engine and voice
together; Theo labels `theo-c4s`. The selected pair persists independently for
each profile across relaunch, with no separate per-engine preference. Environment overrides disable the matching
fields and show `Set by <VAR>`. The threshold selects when automatic long reads
use LONG. Changes apply to the next speak; the UI never writes settings files.

Legacy saved pairs retain the same version-1 file and wire format. Compatible
choices remain selected. Retired Theo variants, Huberman, and unavailable Ben
clone selections normalize on read to installed `theo-c4s`, or Jenny when Theo
is absent. The next explicit settings write persists this migration; health
polls never rewrite the file. Rates and threshold survive. Environment overrides
keep their exact values and lock explanations.

The Preview button sends `{"cmd":"preview_tts_profile","profile":"short","id":"preview-1"}`
(or `long`). The daemon speaks a fixed sample using that profile and acknowledges
with fresh `tts_controls` when playback finishes. Recording, playback, an active
voice operation, or another owner's booking rejects previews without speaking.
Preview does not start the clone daemon. A clone-down warning explains the fast
voice fallback; use `voicelayer daemon` to start the clone engine separately.

Selecting a listed voice in Speech sends its engine and voice in a single atomic
`set_tts_setting` profile command, preserving the rate. The Voice picker waits for
the matching acknowledgment; rejection keeps the daemon's prior pair.
`engine.source: "environment"` locks the combined selection via
`QA_VOICE_TTS_VOICE`, just like the voice field.

The first-sound readout describes the last successful speech request (or Preview)
from request receipt to player start, including synthesis and queue wait.
`last_first_audio_ms` remains compatible; additive `last_first_audio` metadata
contains the actual `engine`, `origin: "preview" | "speak"`, and `fallback` flag.
The UI names the producing engine category rather than assuming the configured
engine played. Without attribution it says “Not measured yet. Press Preview.”

`tts_controls.preview_active` stays true throughout preview synthesis/playback
and becomes false when its reservation is released. A client confirmation timeout
keeps Preview disabled until its matching late ack or explicit idle daemon health.
Health repaints Settings once when successfully parsed Speech controls meaningfully
change (including the first snapshot after reconnect and new latency measurements).
Identical health never repaints again, so the Settings appearance refresh cannot
loop. Malformed or absent controls retain the last successfully parsed snapshot.
Speech admission uses capture/playback and pending speech state; Models refresh
and Whisper load/unload flags do not block Preview. Preparation and playback
status share the inline Preview surface, and rejection acks include controls read
after the preview reservation is released.
