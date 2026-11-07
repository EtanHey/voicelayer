# Selection snapshot helper deadlines

`SelectionPasteboardSnapshot.readInHelper` waits for a readiness byte before it
starts the one-second bound on pasteboard reads, payload output and successful
child exit. Startup has its own five-second bound. Every failure returns no
snapshot, so `SpeakSelectionCapture` never posts Copy against an unsaved board.

The model scales startup/read budgets to four/two ticks and enumerates startup
and provider delays, valid/invalid replies and deadline boundaries. `Current.cfg`
shares the read budget with startup, matching the old watchdog. `ColdDelivery`
uses independent eligibility: a valid reply whose startup and read each fit their
respective budget must succeed. The model abstracts the poll/read loop and exit
as one bounded provider phase; it does not model AppKit, code validation or TCC.

Run on the M1 through `heavy.sh E3-model bash formal/selection-snapshot-startup/check.sh`.
The checker requires every expected exit and the exact violated invariant.

| Config | Mutation / invariant | Required exit |
|---|---|---:|
| Fixed | All five invariants | 0 |
| Current | Share startup/read deadline → ColdDelivery | 12 |
| MutantStartup | Remove startup bound → StartupBound | 12 |
| MutantRead | Remove provider/exit bound → ReadBound | 12 |
| MutantInvalid | Accept invalid reply → ValidDelivery | 12 |
| MutantType | Invalid phase → TypeOK | 12 |

The Swift regression delays readiness beyond the old one-second watchdog, then
runs the real helper against a unique pasteboard and retains every original
provenance/payload/privacy/restoration assertion. Separate fixtures must refuse
missing readiness, malformed replies, failed exit, stalled providers, partial
output and a child that closes stdout without exiting. The startup-timeout test
also proves the main queue remains responsive and the clipboard is untouched.
