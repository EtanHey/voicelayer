| Property | Exact-property failing mutant configs |
| --- | --- |
| CancelledNeverCompletes | CancelThenComplete |
| NoCrossCallerDelivery | ScopeLeak |
| NoDoubleInboxInsertion | NewIdPerClaim |
| NoLossBeforeAck | DeleteOnWrite, CrashDrops |
| NoNewCaptureWhileRecovering | AdmitWhilePending |
| NoTaskResultToOtherCaller | TaskScopeLeak |
| TaskCompletesAfterRow | CompleteOnAccept |
