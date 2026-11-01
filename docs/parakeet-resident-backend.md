# Opt-in resident Parakeet STT

This lab candidate adds a local backend beside the existing Whisper server. It
does not change the default backend or install another daemon/LaunchAgent.

## Configuration

Configure the **VoiceBar-owned MCP daemon's environment** before launching it:

```sh
QA_VOICE_STT_BACKEND=parakeet
VOICELAYER_PARAKEET_PYTHON=/absolute/path/to/venv/bin/python
# Optional when v3 assets are outside the default local cache:
VOICELAYER_PARAKEET_MODEL=/absolute/path/to/parakeet-tdt-0.6b-v3
```

Python must already provide the MLX runtime and `mlx_audio`. The integration was
tested with the SPEED lane's local Parakeet TDT 0.6b v3, mlx-audio 0.6.3, MLX 0.32.4
and Python 3.12. Model configuration, weights and tokenizer must already exist
locally; this backend never downloads assets. Whisper CLI and a local Whisper
model are still needed for fallback. `VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS` and
the existing Models idle setting also control Parakeet (default 600 seconds).

The native picker uses daemon-owned `recognizer=parakeet|whisper`, persisted in
`stt-settings.json`, with `set_recognizer` / `get_recognizer_status` and
`recognizer_status` events. Leave `QA_VOICE_STT_BACKEND` unset or `auto` to use
the picker; an explicit environment override disables preference changes.
`PICKER-API.md` in the Wave2 adapter report lane gives the exact producer contract.
Selecting `parakeet-resident` in the environment is an alias for `parakeet`. `auto`, `resident`,
`whisper-server`, `whisper` and `wispr` retain their previous selection behavior.

## Ownership and lifecycle

VoiceBar owns its MCP daemon. After the daemon validates its parent and acquires
its singleton process lock, it registers as the Parakeet owner. Registration
and later launches require both the matching VoiceBar parent and current
ownership of the daemon PID file. The first
eligible request starts one Python child over private stdin/stdout pipes and
waits for a PID-bound health reply. There is no shared TCP port, foreign-process
adoption or separate service installation. A CLI invocation cannot quietly
create a second resident; it takes the Whisper fallback instead.

The manager serializes requests and restart/unload operations. It drains stderr,
rejects malformed, partial, mismatched or timed-out responses, confirms owned
child exit before replacing it and bounds stream cleanup. Health messages do
not load a model or extend its inference idle timer. Idle unload uses the same
busy-capture/voice-operation policy as existing model residency. It cannot stop
an active request. The Python child also exits if its exact daemon parent dies.

Controlled daemon shutdown stops Parakeet and aborts/waits for any one-shot
Whisper fallback owned by this opt-in route. Startup and request deadlines for
Parakeet are 300 and 120 seconds; a later request may start a new child after a
failure, but a failed request does not repeatedly retry Parakeet.

## Languages and fallback

The persisted picker choice is authoritative: `parakeet` always attempts
Parakeet TDT v3; `whisper` selects Whisper large-v3-turbo. Language hints,
unsupported languages, output scripts and context prompts do not switch engines.
Acoustic language detection is off by default. Auto is not classified English;
unsupported or unknown language hints emit an advisory only. Parakeet may render
unsupported speech as plausible Latin text. The user can explicitly select W.
The native P API does not accept context prompts; a prompt does not force W,
and dictionary aliases remain a separate post-decode operation.

Parakeet errors, missing/full-frame coverage failures, extremely sparse
responses and suspicious late speech/timestamp gaps trigger one full-audio
Whisper retry. A COMPLETE native empty response first runs an isolated Silero
VAD session on the exact full snapshot, using threshold0.3. Only complete,
input-SHA/frame-matched evidence with every window below that threshold can
deliver empty as `VAD_NO_SPEECH` (the UI says "No speech detected"). Whisper is
then NOT_RUN; native output and raw VAD probabilities remain private. Speech
detected, missing/partial/invalid VAD evidence or VAD failure still retries
Whisper. P errors never become no-speech based on VAD.
The gate exists because SPEED found likely hallucinated Whisper fallback text
on three detector-negative originals: 174 valid lexical intervals lay outside
detected speech, with 6 timing unknowns. This is machine evidence, not audio
gold. At the chosen 0.3 probability threshold, all three remain detector-negative
and all three public speech controls remain positive (9.952 / 7.248 / 3.296 seconds).
The lower tested threshold protects quiet speech; equality counts as speech.
Original audio and historical P/W attempts remain immutable. No conditional
gain decode is justified for those originals without a supported speech region. The detector is not
perfect acoustic truth, and never shares or resets live capture RNN state. Parakeet is unloaded first;
fallback uses a one-shot Whisper CLI child so it does not leave a second model
resident when the next Parakeet request arrives.

The sparse/tail tests are conservative retry heuristics. Native word timings
do not prove acoustic completeness. Neither these tests nor a successful retry
proves that all real words were recovered. No audio is cropped, faded, split by
this adapter or matched to expected text. Native Parakeet runs the complete
input with the measured 30-second chunk/2-second overlap settings.

Both providers receive the same private, read-only, byte-identical full-WAV
snapshot. This prevents a replaced recording from invalidating completeness
checks during fallback. The snapshot is removed only after the request settles;
the original recording is never changed or deleted. Non-PCM formats P cannot
decode are still snapshotted byte-for-byte and delegated to Whisper without
making a zero-signal claim.

One narrow silence rule applies **only when every PCM16 sample is exactly zero**:
If the VAD no-speech branch did not apply, Whisper is still retried and its raw
output retained, but generated words are
not delivered from a zero-signal input. There is no RMS/VAD silence threshold;
even one nonzero sample disables this rule. This was motivated by a real lab
case where P returned empty and W produced three raw letters on synthetic zeros.

## Raw text, dictionary and diagnostics

The backend returns Parakeet text unchanged, including repetition, fragments and
tails. VoiceLayer's existing `input.ts` finalization then applies the same built-in
and personal dictionary aliases as for Whisper. No dictionary, expected text or
prompt is sent to Parakeet. This route also omits vocabulary/initial prompts
from the Whisper fallback; an explicit caller continuity prompt is honored. Existing identity/raw finalization mode still bypasses
cleanup; this change does not redesign the existing corrector or formatter.

Before Whisper starts, a fallback writes the raw P alternative (or null when
unavailable), reason and exact input SHA to a private `parakeet-fallbacks` file.
A second append-only record links that first event to the raw W result or
provider error. Interruption during W therefore cannot erase the P boundary. Returned `fallbackEvidencePath` identifies it. Directory/file modes
are 0700/0600. A diagnostic write failure cannot change a returned result or
replace the primary provider error. Original recordings remain in their existing
archive. Partial/invalid JSONL bytes and failed CLI stdout/stderr stay in the
private diagnostic, rather than being classified as empty speech.

`STTResult.outcome` distinguishes native nonempty output, nonempty fallback
with unknown completeness, known truncated capture, invalid fallback timings,
and verified zero PCM. The VAD no-speech outcome separately records W as NOT_RUN, with native and
classifier attempts retained; no W output is manufactured. A nonempty fallback
is explicitly qualified; it does
not claim recovered words. Both-empty, failed or partial fallback throws an
`STTQualificationError` (or the original provider error), retaining both
attempts. The archive backend label carries the route and fallback reason;
existing archive Whisper fields apply only when Whisper actually produced it. No transcript is echoed into manager diagnostics.

## Validation and boundaries

Run focused tests with the normal preload enabled:

```sh
bun test src/__tests__/parakeet-backend.test.ts src/__tests__/parakeet-server.test.ts src/__tests__/parakeet-worker.test.ts
bun run typecheck
```

These tests use fake runtime/private protocol children, never real MLX imports.
The preload uses the same exact `QA_VOICE_GOLDEN_LIVE=1` opt-in for both STT
providers. Without it, Bun spawn interception and PATH Python dispatchers refuse
the real worker script operand or configured nonfixture MLX interpreter with
exit78 and a private fixed-fields refusal record. Later script arguments are
data, so fake-runtime.py can import the worker body with synthetic dependencies.
Canonical fixture paths remain allowed; symlink escapes do not.

On macOS an inherited kernel policy denies the configured interpreter's canonical
executable (including aliases), direct worker execution, and reads of real
`.safetensors` outside canonical fixture roots. Configured model and Hugging Face
cache snapshot entries are resolved before sandbox installation; extensionless
canonical weight blobs receive explicit read denials too. New canonical targets
in an inherited child invalidate its cache and fail closed. Python's worker argument is not
an executable vnode: unwrapped generic Python can read the worker body, but
cannot read its real weights. The kernel returns EPERM; this is separate from
the wrapper's exit78 contract. An active exec/weight canary and configured-runtime
`--version` denial validate cache hits; every configured canonical weight target
also requires a kernel-denied open without reading bytes. Cache metadata alone
cannot grant access, and obsolete policy markers are rejected.
Changing protected interpreters after inheriting the sandbox fails closed and
requires a fresh test process configured before preload. On other platforms,
an installed configured real interpreter fails closed without kernel enforcement.
No real model/import runs as a guard control. Real file-only integration
commands and retained outputs are in the Wave 2 `parakeet-adapter` report lane;
they execute under the shared `ENGINE.lock`. Model comparisons/reference scoring
remain SPEED-owned. The baseline full suite contains auto-enabled live Whisper
golden tests, which now require exactly `QA_VOICE_GOLDEN_LIVE=1` before
any tool probe or live case. The long case also requires
`QA_VOICE_GOLDEN_LONG=1`. Engine-capable suites must still hold that lock; the
preload alone is not engine serialization. Pure detector tests remain ordinary.

This is a lab source candidate, not an installed VoiceBar build or native macOS
permission/release qualification. Contract checks cover advisory-only language
hints without overriding the selected recognizer; no acoustic LID accuracy is claimed. No general
model winner, raw fragment-fidelity guarantee or application speedup follows
from the adapter smoke measurements.

## v3 default and automatic language
The default checkpoint is mlx-community/parakeet-tdt-0.6b-v3 (NVIDIA TDT0.6Bv3), matching SPEED. Default local asset directory: `${XDG_CACHE_HOME:-~/.cache}/voicelayer/models/parakeet-tdt-0.6b-v3`; VOICELAYER_PARAKEET_MODEL overrides it. Missing assets fall back; selecting the backend never downloads them. The Python runtime remains explicit.

With Parakeet opted in, the production unset-language auto path uses multilingual v3; it is not classified English. `STTResult.languageWarning=auto-language-unverified` and a generic diagnostic warn about unsupported speech. Even explicit Hebrew/unsupported language hints keep the selected P and are advisory only.

An experimental `VOICELAYER_PARAKEET_LID_WARNING=1` adds a request-scoped,
detect-only whisper.cpp small-model warning in parallel with P. It is OFF by
default and never changes desired/effective engine, delivered text or fallback
language. Existing `~/.cache/whisper/ggml-small.bin` is used; optional
`VOICELAYER_LID_MODEL` and `VOICELAYER_LID_WHISPER_CLI` override the local paths.
No assets are downloaded. A literal leading PCM prefix of at most30seconds is
submitted only to detect-only; P still receives the entire immutable recording.
Private `languageEvidence` retains input/prefix identity, language/confidence,
wall time and a raw-log path. An unsupported prediction at confidence>=0.8
warns; lower confidence warns without becoming a routing gate. Ordinary detector
failure is UNKNOWN and preserves P's provider result/error. Child exit and both
streams must settle before any fallback; unresolved cleanup holds the request.

The paired lab experiment explicitly permits P and the diagnostic small model
to coexist inside one ENGINE.lock. This opt-in temporarily loads two physical
models; the prior single-engine picker/formal proof does not qualify that
auxiliary path. Default-off preserves the selected-engine residency behavior.
The15-input experiment predicted en for12/12 documentary English controls and
he for3 private machine-labelled candidates, whose acoustic language gold stays
UNKNOWN. Median detect-only wall was485ms and remaining wait after P308ms;
7/12 English estimates were below0.8. This does not justify enabling the warning
by default or using confidence as an English/fallback gate. Backend times and
script-only checks do not establish Hebrew/mixed accuracy or garbage-English
classification. Full commands/raw measurements are in the lane's lid-r1 report.

## Failed selection restoration
A switch confirms prior cleanup before loading its target. On a failed target
load, retain the private error/attempt receipt, clean up the failed launch, and
restore the previous effective engine (or the prior choice if no model was
loaded). This works in both directions. Desired stays the user's requested
choice, while effective and the result backend identify the actually restored
provider. Later requests reuse that provider; legacy W load/effort controls
cannot allocate W beside a restored P. Cleanup uncertainty blocks restoration.
A failed restoration is Error with no effective engine, never a Ready claim.

The default idle timeout remains600seconds for either selected engine. The
real lab daemon switch/idle checks use5seconds only to observe both unloads.

### Owner shutdown and capture priority
Already admitted capture transcription waits for pending legacy Whisper maintenance,
with request priority across the handoff; picker transitions and unknown cleanup still refuse it.
Cancelling that wait releases its request reservation. Owner shutdown closes admissions first,
cancels providers, and joins picker/maintenance, owned startup cleanup, and active requests before
returning. It never restores an engine after owner close; durable desired choice is retained.
An unexpected owned Whisper child exit publishes `whisper-unexpected-exit` immediately for that
exact generation. Intentional unload and a late old exit cannot invalidate a replacement.
Status reads remain free of provider work. These contracts do not establish native/model qualification.
