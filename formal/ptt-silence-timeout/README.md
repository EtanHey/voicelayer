# Locked PTT silence deadline and cap

`bash formal/ptt-silence-timeout/check.sh` uses the shared pinned TLC runner.
Fixed passes all six properties; every mutant must fail its exact named property.
See [MUTANTS.md](results/MUTANTS.md). No state or depth constraint truncates Fixed.

A Tick represents 30 seconds. Detected speech renews the two-tick (60-second)
continuous-silence deadline. The forty-tick (20-minute) hard cap applies during
speech too. Both stops archive and transcribe the complete captured sequence.
`Frame(TRUE)` maps to `processVADChunk`/`isSpeech` updating `pttLastSpeechAtMs`;
`Timeout` maps to the silence timer or hard-cap timer calling `finish`.
The finite PCM alphabet models sequence equality; it does not model STT accuracy.

The real capture fixtures in `input-durability.test.ts` use synthetic PCM,
the isolated recorder stub and a simulated clock. They cover speech past 60
seconds, silence for 60 seconds, and the 20-minute cap, checking all PCM reaches
the archive and decoder. Pending classification defers silence expiration;
failed classification leaves explicit Stop/Cancel and the hard cap available.
VAD does not select or trim PTT audio. This is the changeable ETAN-ASKS.md D3
decision recorded in CLAUDE.details.md. No installed/live or real-mic proof.

| Property | Mutant |
| --- | --- |
| NoTimeoutDuringSpeech | WallClockMutant |
| EveryEndedTakeRetained | DropArchiveMutant |
| RawAccurate | TrimWordsMutant |
| SettlesAfterSilence | StallMutant |
| SpeechRenewsDeadline | NoRenewalMutant |
| CapStops | NoCapMutant |

Temporal checks assume fair clock, timeout and decoder settlement. They do not
assume a delivery acknowledgement. Filesystem failure and VAD/decoder accuracy
are outside this model; focused runtime tests cover archive failure handling.
