| Property | Exact-property failing mutant configs |
| --- | --- |
| EveryEndedTakeRetained | DropArchiveMutant |
| NoPausedAudio | AppendWhilePausedMutant |
| NoTimeoutDuringPause | PauseCountsTowardTimeoutMutant, TimeoutWhilePausedMutant |
| NoTimeoutDuringSpeech | WallClockMutant |
| PausedSpansClosed | OpenSpanMutant |
| RawAccurate | TrimWordsMutant |
| RecurringSpeechNeverTimesOut | ReintroducedCapMutant |
| SettlesAfterSilence | StallMutant |
| SilenceTimesOut | NoTimeoutMutant |
| SpeechRenewsDeadline | NoRenewalMutant |
| StopCancelFromPaused | NoStopWhilePausedMutant |
| UnpausedRetained | ClipAtPauseMutant, NewTakeOnResumeMutant |
