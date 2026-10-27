# Local model residency

Qwen3-TTS weights load on the first authenticated synthesis. MCP daemon startup no
longer starts the local MLX polish server; the first polish request starts it.
Recording-start polish warmup starts a cold server in the background while capture
continues. Transcript delivery includes startup in the normal polish budget; a
server still loading at the deadline returns the cleaned transcript unchanged.
Whisper remains on demand. Concurrent cold requests share the load.

All three use `VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS`, default **600 seconds** after
work finishes. Environment overrides the persisted numeric `idle_unload_seconds`
in `~/.local/state/voicelayer/model-residency.json`, then the default applies.
`VOICELAYER_STATE_DIR` relocates the directory; `VOICELAYER_MODEL_SETTINGS_PATH`
overrides the settings file. Invalid values use the default; zero does not disable
eviction. The environment value must be decimal (for example `600` or `12.5`),
without exponent or hexadecimal notation. Set it separately in the MCP and TTS
daemon environments; only the settings file is shared across processes.
Supported positive values extend up to 2147483 seconds. There is no UI.

Active recording, transcription, voice operations and playback prevent Whisper
and polish eviction, including captures booked by the daemon itself. Active
inference prevents eviction. Requests arriving during eviction wait for
cleanup and then reload. Whisper and polish respect the voice-session
maintenance reservation. Whisper and polish only stop children they own; an
externally managed or adopted server, including an orphan from an earlier daemon,
keeps its owner's lifecycle and is not idle-unloaded here. An explicit Settings
Load is also subject to the idle timeout. Qwen releases
weights and clears MLX's allocator cache while its authenticated HTTP daemon stays
available. MLX load, synthesis and unload execute on one dedicated worker thread.
Health checks report `status: ok` with `model_loaded: false` when Qwen is idle.

`scripts/model-residency-report.sh` prints model process PID and RSS in KiB.
A missing row means no matching process was found. RSS is process memory, not a
measurement of live model weights or Metal allocations. Run it on the installed
build before/after an idle interval to assess residency; it was only exercised
with stub `ps` output for this implementation.

The stub latency test in `src/__tests__/model-residency.test.ts` measures a 25 ms
simulated load and 2 ms simulated inference through the production residency
lease. One run measured cold **29.667 ms**, warm **2.205 ms**. These are timer and
lease measurements, not model-performance estimates. Warm owned polish requests
add no readiness probe. Real-model cold/warm latency, installed RSS and native
`voice_ask` performance: **NOT MEASURED**.
