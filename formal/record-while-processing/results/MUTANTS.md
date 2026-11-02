| Property | Exact-property failing mutant configs |
| --- | --- |
| CapAlwaysFires | MutNoCap, MutCapRenewedBySpeech, MutCapBlockedBySpeech |
| CaptureWithinCap | MutNoCapBound |
| D3EveryTakeKept | MutDropTimeout, DropCancelledMutant |
| EscapeTargetsNewest | MutEscapeMic, MutEscapeOlder |
| EventuallyIdle | MutNoIdle, MutNoDecodeFairness |
| N6Admissible | MutStallRecord |
| N6PreservesA | MutRecordCancels, MutDisableRecordPreserve |
| N6StartsB | MutRejectRecord, MutDisableRecordStart |
| N7CooldownRing | MutRing |
| N7GuardedClick | MutUnguardedClick, MutDisableCancelBGuard, MutDisableClick |
| N7Identity | MutIgnoreIdentity |
| N7ScopedCancel | MutWrongVictim, MutUnscopedSignal, MutDisableCancelB, ConcurrentGlobalCancel |
| N8DecodeAdmissible | MutHeldDecode |
| N8FinalNotSuperseded | MutSupersede |
| N8ImmediatePaste | MutHoldResult, MutResultStopsB, MutDelayedPaste, MutHeldDecodeImmediate |
| NoCancelledPaste | MutPasteAfterCancel |
| NoDuplicatePaste | MutDuplicatePaste |
| NoEarlySilenceTimeout | MutEarlyTimeout |
| NoStaleGuard | MutStaleGuard |
| NoTimeoutWhileTalking | MutSpeechTimeout |
| OneDecoder | MutTwoDecoders |
| OneMic | MutTwoMics |
| OverlapPastes | MutNoOverlapProgress, MutHeldDecodeOverlap |
| ProcessingSettles | MutUnfairProcessing |
| SilenceTimesOut | MutTimeoutNeverFires |
| SpeechRenewsDeadline | MutSpeechNoRenew, MutSpeechDisabled |
| TypeOK | MutType |
