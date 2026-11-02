# History row events during paging

Source-level abstraction for QA-10. No app, microphone or audio playback is used.

`StartPage` captures an archive version. Two `ArchiveWrite` steps may advance it; their
notifications may arrive in either order. `FinishPage` publishes its snapshot. The
fixed path applies each row event immediately, retains only its latest revision during
an in-flight page, and replays that revision after publishing the page.

Source mapping:

- `SettingsArchiveIndex.change` reads one directory off main and assigns its revision.
- `SettingsHistoryArchiveChanges.receive` rejects older notifications and coalesces pending rows.
- Both History `.onReceive` handlers use the main-actor reducer's `receive(..., apply:)` without cancelling the load.
- Both page completions use the reducer's `publish` to apply the page, then replay `takePending()`.
- `SettingsHistoryIncrementalTests` checks these seams and fixture behavior.

Run from the repository root, through the captain's serialized runner:

```sh
~/.local/state/captain-2.2.61/heavy.sh H bash formal/history-row-refresh/check.sh
```

2026-11-02 results (TLC 2.19):

- Old reload: expected FAIL, exit 12, `PagingNotCancelled`; 10 distinct states, depth 4.
- Row patch without replay: expected FAIL, exit 12, `SettledPageIsFresh`; 44 distinct states, depth 7.
- Fixed: PASS, exit 0; 81 generated / 47 distinct states, depth 7, no states left.

Each invariant has a targeted MUTANT config. `check.sh` accepts a mutant only when TLC exits 12 and
reports that exact invariant; a passing mutant, parser error, or failure on another property fails the script.
Small text logs go to `docs.local/lane-h/tlc-fix/`; TLC state goes to `.build.noindex/tlc-history-check/`.

| Property | MUTANT config | Removed guard | Required result |
| --- | --- | --- | --- |
| `PagingNotCancelled` | `OldReload.cfg` | `Incremental = FALSE` | FAIL on `PagingNotCancelled` |
| `SettledPageIsFresh` | `UnfencedPatch.cfg` | `Replay = FALSE` | FAIL on `SettledPageIsFresh` |

The old model abstracts cancellation and does not model the replacement reload.
The freshness invariant applies after both notifications arrive and the page settles.
This finite model covers one row and one page load; it does not prove native text-selection
behavior, Swift runtime scheduling, filesystem atomicity, or multi-row query ordering.
