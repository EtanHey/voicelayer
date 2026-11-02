# Notch presentation — design and production regression checks

Source history starts at `e75a4eb662a534665c36240916ab918a00aabf2c`.
`Current.cfg` retains that policy. `Fixed.cfg` is the intended design, not a claim
that an installed app implements it. No recording mechanics change in this lane.

```sh
bash formal/notch-presentation/check.sh
bash formal/notch-presentation/conformance.sh
```

The first command runs **all** positive, historical-failure and exact-property
mutant configs, then exports both TLC graphs to the runtime corpus. The second
runs the focused real Swift tests. The tests also run by default under `swift test`:
there is no environment variable or `XCTSkip` gate. A checked-in, checksum-bound
`corpus.json` supports a clean checkout before TLC has run.

TLC is pinned by version and SHA-256 in `formal/tlc.lock.json`; its verified jar
lives under `~/.cache/tla/v1.8.0/`. Runs use nice 19, one worker, a 512 MB heap,
seed 1 and fingerprint 0. Raw logs/graphs go to this worktree's `.build.noindex/`.
**Default checks do not rewrite tracked receipts.** Authors explicitly use
`check.sh --record` to refresh normalized traces, the mutant table and corpus.

## Contracts

The renderer model allocates a body from text measurements, control/wing widths,
row counts and inline action slots. Invariants inspect the resulting geometry and
text, not shadow success flags:

- N1 bounds **both wing widths in every mode** by the compact maximum of 132 pt (strictly below the 185 pt core). A visible notice
  has no wing text and its feedback width fits the compact shell. Controls and the
  microphone/waveform lanes remain legitimate wings.
- N2 forbids every text band during processing, including transient feedback and warm-up.
- N3 measures one, two and three-line classes. Allocated band height determines
  `bandLines`, and `N3GrowsDown` requires every visible notice to have a band with capacity for the full requested text, including notes that a faulty renderer leaves outside the band.
  Font wrapping can add lines; the Swift observer separately measures the real font.
- N4 rejects synthesized `Error` **and** `Details below`. The model has an explicit
  absent-diagnostic/available-details input. Separate placeholder mutants exercise
  both halves; Current itself only emits `Error` at this source baseline.
- N5 reads the actual `historyInline` action allocation. There is no
  `busyHistoryInline` shadow field. Removing either the busy or error action fails N5.
- A quit-refusal note clears when the voice/update/preview cause ends. A selection
  rejection owns a finite display TTL. `NoteNeverStuck` is temporal and requires a
  functioning timer; disabling expiry fails its own mutant check.

The finite model samples collapse/hover/History/teleprompter/preview envelopes,
three line classes and details availability. Operational inputs are tested as
projection inputs; not every combination is asserted reachable through every app
caller. Morph curves, acoustic capture and native rendering acceptance are outside
this model. There is no state/depth constraint truncating a positive check.

## Independent production conformance

`LaneGFormalConformanceTests` feeds **both Current and Fixed corpora** to the real
`VoiceBarPresentation.notchPresentation` and resident presentation model. Production
checks independently inspect numeric geometry, measured text heights, full status
and note strings, and History action wiring. They do not assert the Fixed model's
own booleans as proof of the implementation. Numeric wing bounds and grow-down /
no-truncation checks are strict for all applicable frames, including every mode.

The actual compact-status routing is read from `BarView` rather than reproducing a
mode allowlist. Empty expected text requires empty actual body **and** wing text;
extra notes also fail. The feedback label must retain its unlimited-line renderer,
and one/two/three-line error probes must strictly grow in real measured height.
Cause-ending graph edges run through `VoiceState.reportQuitRefusal` and mode changes.

`formal/runtime-contract.json` declares which implementation currently resides in
the checkout. On the baseline, Current comparison is strict; Fixed production gaps
are strict `XCTExpectFailure` assertions, **not skipped tests or Fixed source PASS**.
Lane A changes `notchPolicy` to `fixed` after implementing the ledger, including
cause clearing. Then the Fixed production assertions are strict, and only the
historical Current comparison expects a mismatch. A missing expected mismatch is
also a failure. Every Fixed baseline family additionally has an exact sorted
divergence multiset SHA-256 and count in `results/conformance.json`; those checks
run outside `XCTExpectFailure`, so drift cannot be absorbed by the wrapper.
`FixedProjection` pins the complete expected projection plus actual observation,
including mismatches on frames that were already failing. The input/routing/observation helpers live together in the Swift
harness so a changed presentation API has one explicit adaptation point.

## Source map

| Action / observation | Baseline code |
| --- | --- |
| Operational projection and copy classes | `flow-bar/Sources/VoiceBarUI/VoiceBarPresentation.swift:205`, `:584` |
| Resident envelope / publication | `flow-bar/Sources/VoiceBarUI/VoiceBarNotchPresentationModel.swift:54`, `:109` |
| Geometry and transient body | `flow-bar/Sources/VoiceBarUI/VoiceBarNotchContract.swift:289`, `:371`, `:607` |
| Text measurement, wing allocation and row actions | `flow-bar/Sources/VoiceBarUI/VoiceBarNotchFeedback.swift:35`, `:72`, `:95`, `:138` |
| Full text renderer / no clipping | `flow-bar/Sources/VoiceBarUI/VoiceBarNotchFeedback.swift:150` |
| Selection note cause and expiry | `flow-bar/Sources/VoiceBarUI/VoiceState.swift:1115`, `:1123` |
| Quit-refusal cause and expiry | `flow-bar/Sources/VoiceBarUI/VoiceState.swift:439`, `:449`; `flow-bar/Sources/VoiceBar/VoiceBarApp.swift:1258` |
| Preview cause | `flow-bar/Sources/VoiceBarUI/VoiceBarPresentation.swift:190`; `VoiceState.swift:868` |

The Current counterexamples remain: short error copy occupies a wing; transient
selection feedback adds a processing band; missing diagnostics synthesize `Error`;
busy notes omit History; quit refusal survives its resolved cause until expiry.
Their normalized traces and all mutation results are under `results/`.
See [MUTANTS.md](results/MUTANTS.md) and [run.json](results/run.json).

## Final review additions

`MutCoreWing` rejects a wing equal to the core; `MutOutsideBand` rejects visible
notes omitted from the lower band. The Swift observer has the same 132 pt bound
for every mode. N3 covers all visible notes, and the missing-band baseline family
is explicitly pinned. Real text measurement is strict for 1–3 line probes; above
72 pt the production feedback uses its vertical ScrollView, rather than growing
without bound. This model does not prove native scroll interaction.
