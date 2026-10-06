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
| ndjson-partial-write | Real daemon queue, stalled Unix reader, app's existing Bad JSON and client-registration logs | 0 Bad JSON + missing handled frames |
| socket-isolation | **behavior (overlay: protected-path test seam)**: fake resident survives plain, case, parent-symlink, socket-symlink launches | 0 takeovers/missing refusals |
| retranscribe-history-refresh | MCP voice_ask retry durably writes the original synthetic Ask and sends exactly one archive_metadata_updated to the app connection | 0 missing/extra updates |

R1/R3 app sources are unmodified. R2 adds exactly one isolated fixture path to `SocketBindingPolicy.livePaths`; decision code is byte-identical. The saved patch and SHA-256 accompany every result. Before the policy existed, the patch is empty and FAIL demonstrates actual listener takeover. The lead approved this seam in the 2026-10-06 collab ruling.

To add a row, extend `ROWS` and its real-boundary scenario. Attach commands, exit codes, JSON, and relevant logs for BOTH commits: setup/build failure is not a historical bug receipt. Commit private-safe receipts and quote the full table at the PR head. No personal audio, transcripts, dictionary entries, or UI diagnostics in artifacts. The lead enables the required check after merge; branch protection is untouched. CI runs both SHAs on the same macOS image as the Swift job; the comment workflow executes trusted default-branch code and validates result SHAs before writing. The comment workflow activates after it lands on main. Hosted CI and required-check activation still need their own receipts.

Render a table without writing to GitHub:

```sh
python3 ratchet/comment.py --baseline .verified/ratchet/baseline/result.json --head .verified/ratchet/head/result.json --baseline-sha <main-sha> --head-sha <pr-sha>
```

Add `--pr <number> --repo EtanHey/voicelayer` to upsert the marker-delimited bot comment. Manual human/agent comments are never overwritten. The writer rejects stale SHAs, changed row sets, loosened ceilings, and missing overlay hashes. Run `python3 -m unittest discover -s ratchet -p 'test_*.py'` for unit safety/ingestion checks; these are not real rows.
