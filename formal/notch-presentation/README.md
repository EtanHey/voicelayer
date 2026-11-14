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
the checkout. Here `notchPolicy` is `fixed`, so every Fixed notch projection/ledger/cause check
is strict with zero expected failures. Only the historical Current notch comparison
expects a mismatch. Fixed notch families have exact zero-divergence SHA-256/count
pins in `results/conformance.json`, checked outside any expected-failure wrapper.
The separate pipeline comparison remains under `pipelinePolicy: current` until
Lane I integrates it; its existing nonzero baseline pins remain mandatory.
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
is pinned empty under the Fixed policy. Real text measurement is strict for 1–3 line probes; above
72 pt the production feedback uses its vertical ScrollView, rather than growing
without bound. This model does not prove native scroll interaction.

## Lane A integration (2.2.61)

`formal/runtime-contract.json` now sets `notchPolicy` to `fixed`: the application implements Fixed, its
production assertions are strict, and only the historical Current comparison is an expected mismatch.
Lane A's changes on top of Lane G's round-2 model (union, nothing dropped):

- **Mutants added** (each a different knob from Lane G's): `MutantNoShell` drops only the shell a notice gets
  in a collapsed notch (`VisibleHasShell`); `MutantType` arms a note timer outside 0..2 (`TypeOK`);
  `MutantStuck` re-arms the timer instead of expiring the note (`NoteNeverStuck`, temporal). Lane G's
  `MutNoShell` (every shell idle), `MutType` (negative band height) and `MutNeverExpire` (no expiry) stay.
- **Fixed refinement:** the F5 hint is an operational label, not a notice, so Fixed draws it only as the sole
  content of a compact-status wing (`hinted`): never in a collapsed shell and never beside a visible notice.
  Before, Fixed's `text` kept "preview" where nothing could draw it, and counted it as a band row that
  `TextLines` never budgets. Current is unchanged.
- **Harness adaptation points** (`LaneGFormalConformanceTests.input`, `visibleWing`): the busy-selection note is
  marked through `transientNoteOffersHistory` (production: `VoiceState.selectionFeedbackNoteOffersHistory`)
  instead of being recognised by its copy, and the wing label is read through `wingLabel(for:)`, as `BarView`
  draws it.
- **Production fixes the replay found:** the quit refusal now hides in the same update that ends the voice
  work (`VoiceState.showsQuitRefusal`; only the update-gate part is rechecked), and `transientNoteRect` reports
  the note's own column rather than the full width of a teleprompter body it shares.

## 2.3 N6: one-line confirmations in the right wing

Status acknowledgements use the transient status surface; history contains substantive responses.
moved every idle confirmation into the tab, which was vetoable and is now vetoed for one-line copy.
`N6ConfirmationInWing` (Fixed): a one-line idle confirmation alone in a compact or collapsed notch is the right
wing's label, with no band and a wing within the 132 pt bound. Multi-line recovery copy, long copy and a
confirmation sharing the notch with a note or History stay the tab (N1, N3). `MutTypedTab` restores the
tab and fails exactly N6. The Swift ledger adds an `N6` family read from production geometry and the label
`BarView` draws, and exempts exactly that wing label from the N1 notice check.

## Union with Lane G FIXED-2

All nine notch acceptance properties and all 25 pipeline acceptance properties
are retained. Both mutant sets are registered in `generate-configs.py`, including
A's collapsed-shell, timer-range and rearming variants and G's core-width-wing,
missing-band and never-expire variants. The corpus explicitly carries
`transientNoteOffersHistory`; the fixture passes that metadata directly to the
production operational input. The busy-note fixture uses synthetic copy without the word Busy, so copy matching cannot substitute for that affordance metadata.
Corpus JSON and result receipts are regenerated by TLC, not hand-merged.
