# History row events during paging

Source-level abstraction for QA-10. No app, microphone or audio playback is used.

`StartPage` captures an archive version. Two `ArchiveWrite` steps may advance it; their
notifications may arrive in either order. `FinishPage` publishes its snapshot. The
fixed path applies each row event immediately, retains only its latest revision during
an in-flight page, and replays that revision after publishing the page.

Source mapping:

- `SettingsArchiveIndex.change` reads one directory off main and assigns its revision.
- `SettingsHistoryArchiveChanges.receive` rejects older notifications and coalesces pending rows.
- Both History `.onReceive` handlers patch the row without cancelling the load.
- Both page completions publish the page, then replay `takePending()`.
- `SettingsHistoryIncrementalTests` checks these seams and fixture behavior.

Run from the repository root, through the captain's serialized runner:

```sh
~/.local/state/captain-2.2.61/heavy.sh H tlc -workers 1 -metadir .build.noindex/tlc-history-old -config formal/history-row-refresh/OldReload.cfg formal/history-row-refresh/HistoryRowRefresh.tla
~/.local/state/captain-2.2.61/heavy.sh H tlc -workers 1 -metadir .build.noindex/tlc-history-unfenced -config formal/history-row-refresh/UnfencedPatch.cfg formal/history-row-refresh/HistoryRowRefresh.tla
~/.local/state/captain-2.2.61/heavy.sh H tlc -workers 1 -metadir .build.noindex/tlc-history-fixed -config formal/history-row-refresh/Fixed.cfg formal/history-row-refresh/HistoryRowRefresh.tla
```

2026-11-02 results (TLC 2.19):

- Old reload: expected FAIL, exit 12, `PagingNotCancelled`; 10 distinct states, depth 4.
- Row patch without replay: expected FAIL, exit 12, `SettledPageIsFresh`; 44 distinct states, depth 7.
- Fixed: PASS, exit 0; 81 generated / 47 distinct states, depth 7, no states left.

The old model abstracts cancellation and does not model the replacement reload.
The freshness invariant applies after both notifications arrive and the page settles.
This finite model covers one row and one page load; it does not prove native text-selection
behavior, Swift runtime scheduling, filesystem atomicity, or multi-row query ordering.
