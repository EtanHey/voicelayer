# Per-take stage timings

Completed capture attempts write `stage_timings_ms` into their archive's
`metadata.json` and a matching daemon log entry, including silent, cancelled,
and failed attempts. The log identifies archive IDs and contains no transcript.
All values use the process monotonic clock and are milliseconds:

| Field | Measured work |
| --- | --- |
| `capture_end_to_decode` | Capture completion to backend selection, excluding timed speech gates |
| `decode` | Backend selection, recognition and backend recovery, excluding nested timed gates |
| `dictionary_rules` | Dictionary/rules, punctuation, acoustic paragraph preparation and paragraph formatting |
| `polish` | Optional model polish, including its existing fidelity checks |
| `gates` | Pre-decode speech checks and decoder outro/caption checks |
| `delivery` | Transcript dispatch through the existing delivery acknowledgement, when supported |
| `total` | Capture completion through pipeline settlement, including archive I/O and other overhead |

Stages accumulate across chunks. Zero means skipped or below clock resolution.
The total is not the sum of stages: archive writes, bookkeeping and other
untimed overhead remain in the total. MCP delivery measures dispatch to VoiceBar;
it does not assert that the calling agent has consumed its tool response.
History currently selects explicit metadata fields; its UI lane can read this
additive object without changing capture, decoding or delivery.
