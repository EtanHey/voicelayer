# VoiceLayer ratchet

The [fleet brief](../../orchestrator/docs.local/handoffs/2026-10-06/ratchet-tables.md) sets six rules:

1. Replay observed failures against the real binary/service, prove FAIL at `bug_sha` and PASS at `fix_sha`, and record both.
2. Add rows for bugs that recurred or needed repeated fixes.
3. Require `ratchet`; a missing binary, socket, or event is FAIL.
4. Post main baseline, PR result, delta, ceiling, and status as a PR comment.
5. Tighten/add only; loosening or removing requires a lead ruling in the PR body.
6. Mocks are `unit` evidence and do not count as rows.

Run on macOS with the Swift CI toolchain, Python 3.12+, and Bun:

```sh
python3 ratchet/run.py --ref HEAD --output .verified/ratchet/head
python3 ratchet/run.py --row ndjson-partial-write --ref '78a43fbb^1' --output .verified/ratchet/R1-bug
python3 ratchet/run.py --row ndjson-partial-write --ref 78a43fbb --output .verified/ratchet/R1-fix
```

The runner builds clean detached commit worktrees and launches the real debug app/full MCP daemon on throwaway sockets, state, and temp roots. Both canonical and legacy overrides are required for older commits. Cleanup targets only its own processes/worktrees. No resident sockets, microphone, installed app, or port 8178 are used. R3's deterministic STT executable fixture tests archive durability/notification, not recognition quality.

| Row | Boundary | Ceiling |
|---|---|---|
| ndjson-partial-write | Real daemon queue, stalled Unix reader, app's existing Bad JSON and client-registration logs | 0 Bad JSON + missing handled frames; absent pressure evidence is FAIL |
| socket-isolation | **behavior (overlay: protected-path test seam)**: fake resident survives plain, case, parent-symlink, socket-symlink launches | 0 takeovers/missing refusals |
| retranscribe-history-refresh | MCP voice_ask retry durably writes the original synthetic Ask and sends exactly one archive_metadata_updated to the app connection | 0 missing/extra updates |
| recents-newest-after-retranscribe | **behavior (overlay: trigger + snapshot + defaults-domain test seams)**: real History retry restores the newest cancelled capture first, inserts a missing older recovery chronologically, and updates an existing older row in place | 0 ordering/age/membership violations |

R1 requires harness evidence: a small receive buffer held unread for at least 0.5 s, queued bytes filling that buffer, a sent frame larger than the buffer and maximum recv chunk, and at least one NDJSON frame spanning multiple recv calls. The wire receipt records these values; absent evidence is `pressure not exercised` (FAIL). This proves the exercised pressure/fragmentation seam without observing or modifying product write-return values. R3 waits up to 10 s for a complete update matching the original Ask, then requires 1 s without further received bytes (12 s total bound including margin); missing events, late duplicates, and incomplete frames fail. Setup exceptions clean up the registered worktree and temp root.

R1/R3 app sources are unmodified. R2 adds exactly one isolated fixture path to `SocketBindingPolicy.livePaths`; decision code is byte-identical. The saved patch and SHA-256 accompany every result. Before the policy existed, the patch is empty and FAIL demonstrates actual listener takeover. The lead approved this seam in the 2026-10-06 collab ruling.

The Recents row pins `575ca6ce7950b3e1c5ebe0edd9d97b3958e56c25` (the first parent of #244, including #243's cancel recovery UI) to `2f2de18c1c19339379375df7b9475c99704f2eed` (#244). #244 supplies both immutable archive creation/latest metadata and chronological Recents insertion; #243 does not implement either ordering half. The row uses four synthetic dictation archives, a two-entry synthetic persisted Recents seed, and the same deterministic STT executable as R3. It requires actual daemon finals and durable transcript/metadata before measuring the app's array through its log; no mock state reducer is used.

The Recents scratch overlay exposes two private IPC inputs: one calls the existing `retranscribeHistoryEntry` method, the other logs the actual array plus pending/mode state. It also remaps only the four Recents load/save `UserDefaults.standard` references to an absolute defaults domain under a fresh physical `~/.vlv/pdv-k-*` root: the existing app QA defaults suite alone does **not** isolate these methods. App and Recents defaults, archives, sockets, and daemon state stay under that root, which cleanup removes. The ordering reducer and daemon are unchanged; patch bytes and SHA-256 are saved for each build and the comment labels this overlay. A 45-second owned-daemon deadline prevents its unchanged production-log rotator reaching its first 60-second tick. Missing finals, snapshots, seeds, sockets, binaries, or durable files fail. The lead approved these three seams in the lane K collab ruling; every run records a before/after `defaults read com.voicelayer.voicebar` fingerprint and proves the Recents plist was read and written beneath its isolated root. Personal preference contents are never saved or printed. An absent resident defaults domain on CI is recorded explicitly; unexpected defaults-probe failures fail the row.

```sh
python3 ratchet/run.py --row recents-newest-after-retranscribe --ref '2f2de18c^1' --output .verified/ratchet/R4-bug
python3 ratchet/run.py --row recents-newest-after-retranscribe --ref 2f2de18c --output .verified/ratchet/R4-fix
python3 ratchet/run.py --row recents-newest-after-retranscribe --ref origin/main --output .verified/ratchet/R4-main
```

Committed Recents receipts: [bug](receipts/R4-bug-recents.json), [fix](receipts/R4-fix-recents.json), [main](receipts/R4-main-recents.json), with each saved overlay and normalized app/daemon logs beside the JSON. Only synthetic root paths are replaced with `$ISOLATED_ROOT`; decision code and overlay bytes are unchanged. The recorded runner hash binds the execution receipt to the harness. Observed values are 11 / 0 / 0 respectively, ceiling 0; all three setup/build/event checks completed with no error and unchanged resident-defaults fingerprints. The main receipt measures `a43b3646c9cf8b0eb3e5db27334323f97c7a601b`, not a later PR head.

To add a row, extend `ROWS` and its real-boundary scenario. Attach commands, exit codes, JSON, and relevant logs for BOTH commits: setup/build failure is not a historical bug receipt. Commit private-safe receipts and quote the full table at the PR head. No personal audio, transcripts, dictionary entries, or UI diagnostics in artifacts. The lead enables the required check after merge; branch protection is untouched. CI runs both SHAs on the same macOS image as the Swift job; the comment workflow executes trusted default-branch code and validates result SHAs before writing. The comment workflow activates after it lands on main. Hosted CI and required-check activation still need their own receipts.

Render a table without writing to GitHub:

```sh
python3 ratchet/comment.py --baseline .verified/ratchet/baseline/result.json --head .verified/ratchet/head/result.json --baseline-sha <main-sha> --head-sha <pr-sha>
```

Add `--pr <number> --repo EtanHey/voicelayer` to upsert the marker-delimited bot comment. Manual human/agent comments are never overwritten. The writer rejects stale SHAs, changed row sets, loosened ceilings, and missing overlay hashes. Run `python3 -m unittest discover -s ratchet -p 'test_*.py'` for unit safety/ingestion checks; these are not real rows.
