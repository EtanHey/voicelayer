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

R1 requires harness evidence: a small receive buffer held unread for at least 0.5 s, queued bytes filling that buffer, a sent frame larger than the buffer and maximum recv chunk, and at least one NDJSON frame spanning multiple recv calls. The wire receipt records these values; absent evidence is `pressure not exercised` (FAIL). This proves the exercised pressure/fragmentation seam without observing or modifying product write-return values. R3 waits up to 10 s for a complete update matching the original Ask, then requires 1 s without further received bytes (12 s total bound including margin); missing events, late duplicates, and incomplete frames fail. Setup exceptions clean up the registered worktree and temp root.

R1/R3 app sources are unmodified. R2 adds exactly one isolated fixture path to `SocketBindingPolicy.livePaths`; decision code is byte-identical. The saved patch and SHA-256 accompany every result. Before the policy existed, the patch is empty and FAIL demonstrates actual listener takeover. The lead approved this seam in the 2026-10-06 collab ruling.

To add a row, extend `ROWS` and its real-boundary scenario. Attach commands, exit codes, JSON, and relevant logs for BOTH commits: setup/build failure is not a historical bug receipt. Commit private-safe receipts and quote the full table at the PR head. No personal audio, transcripts, dictionary entries, or UI diagnostics in artifacts. The lead enables the required check after merge; branch protection is untouched. CI/comment automation is a separate stacked PR.
