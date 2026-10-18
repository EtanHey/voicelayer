# VoiceBar release runbook — the T3 Option+F5 gate

> Etan, 2026-10-18: "the fact t3 code mark+option+f5 broke like that is an unacceptable
> regression ... make sure it absolutly never happens again".

2.2.45 shipped with Option+F5 broken in T3 Code. Back then the T3 check was an acceptance
rule, and nothing in the release path consumed it. Now VoiceBar reaches users through one
script, `scripts/promote-voicebar-release.sh`, and that script **refuses** without a matching
installed-candidate T3 Option+F5 PASS proof. It does both delivery steps itself: the
release-asset upload, and the `EtanHey/homebrew-layers` formula and cask commit and push.

- **Never write the tap by hand**: no hand edit, commit or push of `Formula/voicelayer.rb` or
  `Casks/voicebar.rb`, and no raw `gh release upload` of `VoiceBar.zip`. Those skip the gate.
- There is no bypass flag or env var.
- `release-voicebar.sh --upload` is retired: that script always rebuilds, and a fresh build is
  newer than any proof.

npm publication is separate. It is CI-only (`.github/workflows/publish.yml`, OIDC), and CI
cannot produce native proof, so CI is not gated on it.

## Order

1. **Build the candidate.** `scripts/release-voicebar.sh --skip-tap-check`. It prints the
   zip sha256. Tag the release so CI publishes the npm package.
2. **Install exactly that build on the MBP** and relaunch VoiceBar. Install it from that
   `VoiceBar.zip` or app, not through the cask: the cask is what reaches users, so it cannot
   come first. Confirm with `scripts/voicelayer-deploy-check.sh` → `DEPLOYED`.
3. **Produce the proof** (below), with output muted.
4. **Promote:**
   ```bash
   NPM_SHA="$(curl -fsSL https://registry.npmjs.org/voicelayer-mcp/-/voicelayer-mcp-X.Y.Z.tgz | shasum -a 256 | awk '{print $1}')"
   scripts/promote-voicebar-release.sh --version X.Y.Z \
     --app dist/voicebar-release/X.Y.Z/VoiceBar.app \
     --zip dist/voicebar-release/X.Y.Z/VoiceBar.zip \
     --tap-root ~/Gits/homebrew-layers \
     --formula-sha256 "$NPM_SHA" \
     --t3-proof docs.local/<release>/t3-optf5-proof.json
   ```
   The tap must be clean. In order, the script:
   1. verifies the artifact against the proof;
   2. uploads the ZIP;
   3. downloads the published asset and requires it to be byte-identical;
   4. writes the formula (npm url + sha256) and the cask (version + ZIP sha256);
   5. runs the tap-check verification with the proof;
   6. commits both files and pushes.

   Any failure stops it. The tap is not touched before the published asset is confirmed, and
   its edits are reverted if the tap check fails.

The gate refuses, with a non-zero exit and a message naming the problem, when:

- the proof is missing or is not valid JSON;
- it is not a `release` receipt (see below);
- its `bundleSha256` is not the full-content digest of the app being delivered (same
  `GitCommit`/`BuildTimeUTC` with different contents is refused);
- its `gitCommit` or `buildTimeUTC` differs from the candidate `Info.plist`;
- it is older than the candidate's `BuildTimeUTC` (stale);
- any entry of `VoiceBar.zip`'s `VoiceBar.app` differs from the verified app's, including
  the bundled daemon sources, or either side has an entry the other lacks;
- (tap check) the cask `sha256` is not `VoiceBar.zip`'s;
- `expectedTextSha256` differs from `historyTextSha256`;
- the evidence-excerpt hashes are missing, `speakTextCommandId` is not a UUID, `t3Build` is
  empty, or `readError` is not exactly `false`.

## Producing the proof

The helper reads the resident's real artifacts only. It never presses keys: the operator, or
a harness that sends a real CGEvent, does the Option+F5.

1. Write a fresh synthetic paragraph to a file, and post the same paragraph so it renders in
   a T3 assistant message. Keep it to one short plain sentence with no markdown, so the TTS
   history text is the selection verbatim. Use only public text.
2. Arm:
   ```bash
   bun scripts/t3-optf5-proof.ts start \
     --state docs.local/<release>/t3-proof-state.json \
     --t3-app "/Applications/T3 Code (Alpha).app" \
     --expected-text-file docs.local/<release>/synthetic.txt
   ```
   This records:
   - the installed `/Applications/VoiceBar.app` `GitCommit`, `BuildTimeUTC` and full-content
     digest;
   - the T3 build;
   - the current end of `~/Library/Logs/voicelayer/voicebar-err.log`;
   - the time.

   It refuses unless exactly one VoiceBar runs from the installed bundle, with an
   `mcp-server-daemon` child. Both processes must have started in a later second than the
   bundle was installed, and the VoiceBar process's mapped executable (per `lsof`) must be
   the very file installed at the bundle path. So a bundle swapped under an old running
   VoiceBar, including a staged directory moved into place, cannot certify itself.
3. With output muted, select the paragraph in the rendered assistant message (not the
   composer) and press **Option+F5 once**. Let it finish.
4. Collect:
   ```bash
   bun scripts/t3-optf5-proof.ts finish \
     --state docs.local/<release>/t3-proof-state.json \
     --out docs.local/<release>/t3-optf5-proof.json
   ```
   The helper reads only what the resident wrote after `start`, and requires all of these:
   - the bundle digest is unchanged since `start`;
   - exactly one `selection_capture`, logged by that same VoiceBar process, with
     `frontmostApp=com.t3tools.t3code` and `outcome=completed` (any other outcome is a read
     error);
   - a `utf16_count` equal to the expected paragraph's length (one trailing newline from a
     triple-click is tolerated), which ties the capture to the paragraph without logging text;
   - exactly one `speak_text` command UUID since `start`, and it comes after the capture;
   - exactly one new TTS history entry (`/tmp/voicelayer-history.json`), within 30 s of the
     capture.

   It stores hashes only, never the paragraph text (RULINGS 2026-10-18T02:53Z: request logs
   stay redacted). That includes the sha256 of the capture line, the `speak_text` line and the
   history entry. A hash mismatch still writes the failing proof as a record and exits
   non-zero. The gate refuses that proof too.

Any failure means the release is NOT live. Fix forward; do not edit the proof.

**Release vs test receipts.** A proof is a `release` receipt only when it is collected from
the resident's real paths: `/Applications/VoiceBar.app`, the VoiceBar log and
`/tmp/voicelayer-history.json`. The `--app`, `--voicebar-log` and `--history-file`
overrides work only under the bun test preload. Their proofs are `test` receipts, and the
gate rejects those.

`bun scripts/t3-optf5-proof.ts bundle-digest --app PATH` prints a bundle's digest.

## Known limits

- The threat model is accidental omission, not malicious forgery (lead ruling, 2026-10-18).
  Cryptographic anti-forgery is out of scope. `check` validates the proof JSON against the
  delivered bundle and does not re-read the resident's logs, so a hand-written proof would
  pass. Never write or edit one by hand.
- The `speak_text` command UUID is not on the `selection_capture` line. It is tied to the
  keypress by the time window, the single-command rule and the length match, not by an
  id. Logging the id on the capture line needs a VoiceBar change.
- Nothing in `EtanHey/homebrew-layers` itself rejects a hand-written tap commit yet. A
  tap-repo CI check is a separate follow-up. Until then, this runbook forbids raw tap writes.
