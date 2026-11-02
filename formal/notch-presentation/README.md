# Notch presentation: current counterexamples and proposed policy

Source baseline: `e75a4eb662a534665c36240916ab918a00aabf2c` (captain 2.2.61 integration base).
These models change no application code. **Fixed PASS is a design check, not a claim that Lane A's implementation or the installed app passes.**

Run from the repository root:

```sh
bash formal/notch-presentation/check.sh
bash formal/notch-presentation/conformance.sh
```

`check.sh` runs the installed `~/.cache/tla/tla2tools.jar` using
`nice -n 19 java -Xmx512m -XX:+UseParallelGC -cp ... tlc2.TLC`, one worker,
seed 1, fingerprint 0. Each run has private temporary state directories under
`.build.noindex/notch-presentation/`; TLC logs remain in `results/`.
The installed jar is TLC 2.19 (2024), which lacks `-noGenerateSpecTE`.
The runner requires exit 12 and the exact named invariant for a negative check;
a parse error, timeout, unexpected violation or successful negative check fails the runner.
Both positive checks also check temporal liveness, without depth/state constraints.
`results/run.json` binds the source files, spec, configs, runner and TLC jar by
SHA-256; source/spec/config/runner changes during a run invalidate the receipt.

`conformance.sh` converts every Current TLC state into an input/expected projection,
deduplicating only timer/raised/cause fields that the renderer cannot observe.
It runs `LaneGFormalConformanceTests` through the captain's heavy-job lock, against
the real `VoiceBarPresentation`, `VoiceBarNotchContract`, and resident
`VoiceBarNotchPresentationModel`. No source extraction, replacement resolver,
installed app, input synthesis, audio or windows are involved. This is a historical
current-policy replay: its tests skip unless the TLC corpus is explicitly supplied.
After integration changes the policy, update the replay to the new implementation;
do not require the application to preserve the historical bugs.

## Ledger semantics and bounds

- N1: every visible notice uses compact feedback and carries no separate wing label.
  Hardware/control/waveform wings still exist. This is a categorical contract, not
  a pixel-width or shader proof. Feedback sharing the expanded History/teleprompter
  body counts as expanded in Current; Fixed specifies a compact feedback variant.
- N2: **all** note/status bands are absent while transcribing, including warming.
  Current's exclusion of status text does not exclude `transientNote`.
- N4: no synthesized `Error` or `Details below` placeholder. Current generates
  `Error` for an empty diagnostic; it does not generate `Details below` here.
  Fixed hides absent diagnostics instead of inventing replacement copy.
- N5: Open History is inline with an error or busy notice. Current already does
  this for error status, but not for the transient busy-selection note.
- A quit-refusal note must disappear when voice/update work stops blocking quit.
  Ordinary selection rejection notices instead have their own finite display TTL.
  Busy-selection notes clear on the voice phase ending, as current code already does.
- F5 preview hints are operational labels, not notices. They are projected and
  replayed, but N1 applies once a feedback notice is visible, not to the bare hint.
- `NoteNeverStuck` is a temporal property, not an invariant named "eventually".
  Weak fairness of `Expire` models a functioning UI timer; scheduler failure is
  outside the proof. Each of three notice kinds may be raised once, allowing
  replacement before expiry without modelling an unbounded stream of fresh user requests.

Six operational modes, four copy classes, four note classes, two timer steps,
and Boolean History/teleprompter/hover-or-focus/collapse/update/F5-preview envelopes are finite.
Envelopes are sampled initially, not a model of pointer movement or morph physics.
`SetMode` deliberately accepts every operational projection input; a combination
checked by the resolver is not necessarily reachable through every app caller.
Short/long copy classes abstract font measurement at the default core width.
"Select text first" uses its real two-line copy; in History the narrow top wing
overflows into the note band. Recording command/clip labels, queue badges,
teleprompter synchronization, N3 animation, and macOS rendering are outside this model.

## Action to code map (baseline line numbers)

| Model action/operator | Current implementation |
| --- | --- |
| `Init`, envelope fields | `flow-bar/Sources/VoiceBarUI/VoiceBarNotchPresentationModel.swift:33`, `:54`, `:87`, `:93`, `:99` |
| `SetMode`, `SetStatus` | `flow-bar/Sources/VoiceBarUI/VoiceState.swift:396`, `:457`; `VoiceBarPresentation.swift:205`, `:584` in the same UI directory |
| `ShowNote("busy"/"rejection")` | `flow-bar/Sources/VoiceBarUI/VoiceState.swift:1123`, `:1263`, `:1359` |
| `ShowNote("quit")`, `EndUpdate` cause | `flow-bar/Sources/VoiceBarUI/VoiceState.swift:439`, `:449`; `flow-bar/Sources/VoiceBar/VoiceBarApp.swift:1258` |
| `Normalize`, busy-cause clearing | `flow-bar/Sources/VoiceBarUI/VoiceState.swift:400`, `:872`, `:1115` |
| `Expire` | `flow-bar/Sources/VoiceBarUI/VoiceState.swift:454` (6 s quit), `:1128` (2 s selection) |
| `EndPreview`, preview-busy cause | `flow-bar/Sources/VoiceBarUI/VoiceBarPresentation.swift:190`; `VoiceState.swift:868`, `:872` |
| `Project`, compact/retained-body priority | `flow-bar/Sources/VoiceBarUI/VoiceBarPresentation.swift:205`; `VoiceBarNotchContract.swift:289`, `:307` |
| `Project`, note band and status exclusion | `flow-bar/Sources/VoiceBarUI/VoiceBarNotchContract.swift:371`, `:607`; `VoiceBarNotchFeedback.swift:51`, `:57`, `:72` |
| `Project`, inline History | `flow-bar/Sources/VoiceBarUI/VoiceBarNotchFeedback.swift:65`, `:105`, `:138` |
| Resident publication (`Publish`) | `flow-bar/Sources/VoiceBarUI/VoiceBarNotchPresentationModel.swift:109`, `:133` |
| Fixed-only changes | Intended projection/cause policy above; no current implementation is asserted |

## Counterexamples for the captain

Full shortest traces, including the exact projected fields, are in the linked logs.

| Config / violated property | Trace and consequence |
| --- | --- |
| [OldWing](results/OldWing.log) / `N1CompactNote` | idle -> error with empty diagnostic -> lower note plus wing label `Error`; meaningful short `Busy` likewise retains its wing label in the real resolver replay |
| [OldProcessingNote](results/OldProcessingNote.log) / `N2NoProcessingBand` | idle -> transcribing -> selection-busy note -> `band = TRUE` even though processing status text is suppressed |
| [OldSubstitute](results/OldSubstitute.log) / `N4NoSubstitute` | idle -> error with empty diagnostic -> `text = "Error"` |
| [OldBusyHistory](results/OldBusyHistory.log) / `N5InlineHistory` | idle with F5 preview active -> busy-selection note -> visible band with `busyHistoryInline = FALSE`; recording/transcribing busy notes have the same missing action |
| [OldQuitCause](results/OldQuitCause.log) / `NoteHasCause` | idle with F5 preview active -> quit refused -> preview ends -> quit note remains until its six-second expiry; update/voice completion has the same lifecycle; **not** an infinite-stuck finding |

[Current](results/Current.log) checks type/projection consistency, visible shell,
and eventual note expiry; it deliberately does not assert the known-failing ledger rows.
[Fixed](results/Fixed.log) checks those properties plus all five ledger/cause invariants.
See the committed logs and [conformance receipt](results/Conformance.log) for measured counts. Fixed's proposed
compact projection and cause clearing still need Lane A integration and native acceptance.
