# Post-merge deploy checklist

> Build-green and PR-merged is **not** deployed. A merge bumps the version in
> the repo, but the daily-driver keeps running whatever `/Applications/VoiceBar.app`
> was last built — until you actually rebuild + relaunch. This checklist closes
> the gap between "merged to main" and "the running Mac has it" (the recurring
> stale-app regression; "the stack didn't transfer to the M1").

## TL;DR — one command

```bash
scripts/voicelayer-deploy-check.sh
# or: bun run src/deploy-check-cli.ts
```

- **exit 0 + `RESULT: DEPLOYED`** — the merged artifact is built into the
  installed app and the stack is live. Nothing to do.
- **exit 1 + `RESULT: NOT DEPLOYED`** — the running stack is stale. Follow the
  per-check remedy printed in the report (usually `voicelayer update`).
- **exit 0 + `RESULT: INCONCLUSIVE`** — this box is not expected to run VoiceBar
  (CI / remote / non-macOS). Skipped, not failed.

## What it checks (and why)

Each signal is machine-observable; the verdict logic is the deterministic core
in `src/deploy-check.ts`, gated by a CI RED→GREEN suite
(`src/__tests__/deploy-check.test.ts`) that proves it CATCHES every flavor of
"not actually deployed".

| Check | Signal | Why it matters |
|-------|--------|----------------|
| `app-present` | `/Applications/VoiceBar.app` exists | Nothing was ever deployed here. |
| `app-build-provenance` | bundled `Contents/Resources/package.json` version == repo version | `voicelayer build-app` copies the repo `package.json` into the bundle, so a mismatch means the merged code never rebuilt the app. |
| `app-plist-version` | `Info.plist` `CFBundleShortVersionString` == repo version | The marketing version users/agents see is stale. |
| `voicebar-running` | `VoiceBar` process alive | A fresh app that isn't running is still stale at runtime. |
| `voicebar-process-fresh` | oldest matching `VoiceBar` process start time is not older than the installed bundle | A rebuilt app on disk is not deployed until the running app has restarted from it. |
| `daemon-child-alive` | `mcp-server-daemon` child alive | The audio path is down even if the app is up. |
| `daemon-child-fresh` | oldest matching `mcp-server-daemon` start time is not older than the installed bundle | A stale daemon child can keep serving old code after the app bundle was rebuilt. |

## Standard deploy flow (when the check fails)

1. **Deploy the merged code to this machine:**
   ```bash
   voicelayer update            # cross-machine updater: package → rebuild app → restart stack
   ```
   or, for a local checkout:
   ```bash
   voicelayer build-app         # rebuild + reinstall /Applications/VoiceBar.app, then restarts the stack
   ```
2. **Re-run the check** until it reports `DEPLOYED`:
   ```bash
   scripts/voicelayer-deploy-check.sh
   ```
3. **For daemon/socket/MCP-touching PRs**, also run the runtime verification gate
   (real F5 → speak → paste round-trip) and add the `Verified-Runtime: <sha>`
   marker — see `scripts/voicelayer-verify.sh` and the daemon-verification-gate
   workflow.

## Notes

- Version sync: `flow-bar/bundle/Info.plist` `CFBundleShortVersionString` is
  hand-maintained — bump it together with `package.json` so `app-plist-version`
  stays green after a release.
- Override the app location with `VOICEBAR_APP_PATH=/path/to/VoiceBar.app`.
- Force the off-target verdict with `VOICELAYER_DEPLOY_CHECK_APPLICABLE=0`
  (auto-detected on CI / non-macOS).
