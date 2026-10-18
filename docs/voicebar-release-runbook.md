# VoiceBar release runbook — the T3 Option+F5 gate

> Etan, 2026-10-18: "the fact t3 code mark+option+f5 broke like that is an unacceptable
> regression ... make sure it absolutly never happens again".

2.2.45 shipped with Option+F5 broken in T3 Code. Back then the T3 check was an acceptance
rule, and nothing in the release path consumed it. Now the last local step before users
can receive a build will **refuse** unless there is a matching installed-candidate T3
Option+F5 PASS proof. That step is the tap-check run of `scripts/verify-voicebar-release.sh`,
which must pass before the `EtanHey/homebrew-layers` cask bump is committed. There is no
bypass flag or env var.

npm publication is separate. It is CI-only (`.github/workflows/publish.yml`, OIDC), and CI
cannot produce native proof, so CI is not gated on it. Users get VoiceBar through the cask,
so the cask bump is where the gate lives.

## Order

1. **Build the candidate.** `scripts/release-voicebar.sh --skip-tap-check`.
   A fresh build is always newer than any existing proof, so the build itself never needs
   one. It prints the zip sha256.
2. **Install that candidate on the MBP** and confirm it is the one running
   (`scripts/voicelayer-deploy-check.sh` → `DEPLOYED`; the installed `Info.plist` `GitCommit`
   equals the candidate's).
3. **Produce the proof** (below), with output muted.
4. **Bump the tap locally** (`Formula/voicelayer.rb`, `Casks/voicebar.rb`), but do not commit.
5. **Run the gate:**
   ```bash
   scripts/verify-voicebar-release.sh --version X.Y.Z \
     --app dist/voicebar-release/X.Y.Z/VoiceBar.app \
     --zip dist/voicebar-release/X.Y.Z/VoiceBar.zip \
     --tap-root ~/Gits/homebrew-layers \
     --t3-proof docs.local/<release>/t3-optf5-proof.json
   ```
6. **Only on `PASS`**, commit and push the formula and cask together.

The gate refuses, with a non-zero exit and a message naming the problem, when:

- the proof is missing or is not valid JSON;
- its `gitCommit` differs from the candidate `Info.plist` `GitCommit`;
- it is older than the candidate's `BuildTimeUTC` (stale);
- `expectedTextSha256` differs from `historyTextSha256`;
- `speakTextCommandId` is not a UUID, `t3Build` is empty, or `readError` is not exactly `false`.

## Producing the proof

The helper reads the installed app's real artifacts only. It never presses keys: the
operator, or a harness that sends a real CGEvent, does the Option+F5.

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
   This records the installed VoiceBar `GitCommit`, the T3 build, the current end of
   `~/Library/Logs/voicelayer/voicebar-err.log`, and the time.
3. With output muted, select the paragraph in the rendered assistant message (not the
   composer) and press **Option+F5 once**. Let it finish.
4. Collect:
   ```bash
   bun scripts/t3-optf5-proof.ts finish \
     --state docs.local/<release>/t3-proof-state.json \
     --out docs.local/<release>/t3-optf5-proof.json
   ```
   The helper reads only what the resident wrote after `start`, and requires all of these:
   - exactly one `selection_capture` with `frontmostApp=com.t3tools.t3code` and
     `outcome=completed` (any other outcome is a read error);
   - exactly one following `speak_text` command UUID;
   - exactly one new TTS history entry (`/tmp/voicelayer-history.json`), within 30 s of the
     capture.

   It stores hashes only, never the paragraph text (RULINGS 2026-10-18T02:53Z: request logs
   stay redacted). A hash mismatch still writes the failing proof as a record and exits
   non-zero. The gate refuses that proof too.

Any failure means the release is NOT live. Fix forward; do not edit the proof.

Defaults can be overridden with `--app`, `--voicebar-log` and `--history-file`. These only
say where to read, so they are not bypasses.
