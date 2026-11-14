| Property | Exact-property failing mutant configs |
| --- | --- |
| BoundedDelivery | NoDeadline |
| DeadlineBound | LateMain |
| DrainBounded | DrainWorker |
| ExactlyOneOutcome | NoQuitReceipt, PartialPosted, TwoReceipts, PartialUnsupported |
| MainNeverWaits | MainWait |
| NoAXAfterExpiry | LateAX |
| NoLostCharacter | DropUnknown, ForeignRead, PreBreak |
| NoPostToChangedApp | BatchUnguarded, CheckAwaitPost, FallbackUnguarded, FirstUnguarded |
| NoSegmentWithoutFreshCheck | AgedCheck, Stale |
| PlainTextUntouched | PlainList |
| RecordingNeverBlocked | BlockRecording |
| SlowNeverLoses | DropSlow |
