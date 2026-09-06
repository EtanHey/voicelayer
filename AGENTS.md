# VoiceLayer

VoiceLayer is how I talk to my agents and how they talk back. I've been dictating through VoiceBar
and F5 for a long time and that part does its job well. Asking is newer — I've been leaning on
`voice_ask` heavily since late July 2026, gaining more and more experience with it, and it's become
the thing that stops me losing answers and stops me getting walls of text I skim without actually
understanding. I keep all this — rather than just paying for Wispr Flow — for three reasons: I can
control it exactly how I want, the notch app we built beats anything that blocks my screen, and it's
local-first. It hasn't replaced Wispr Flow, because Wispr Flow runs on my iPhone and this
unfortunately doesn't, so this is what I use at my desk or pacing around the room. And there's still
real work here: the teleprompter and the speech aren't synced at all — I can't click a word to jump
back or scrub to a moment, so I end up waiting out the audio and reading the text from the MCP
instead. I'm looking for things like that that would complete the UX, so other people installing
this app can use it — or help, if they ever try to.

## What I care about most

That what comes out is what I actually said. Today it drifts three ways — words get added that I never
said, a sentence sometimes repeats back-to-back in a long transcript, and words I did say just vanish.
All of it needs fixing — it isn't either/or. We fixed one of
these by trimming and it cut real tails off my sentences. Don't fix it that way again — a fix that
loses my words is worse than the bug.

Don't cut me off mid-thought. If I'm still talking there's no reason to time out — wait for me to
think. Time out on silence, not on me. And every recording is kept — cancelled, timed out, all of
them.

I want to be able to interrupt you mid-question and have you hear me. Barge-in was built and merged
in May and then never wired into the live ask path — before anyone connects it, test whether that
code is actually good enough to keep.

My MCP connection shouldn't die when VoiceLayer updates, or when an agent swaps in its own build to
test it. Check I'm not mid-sentence before you swap anything.

## Hard boundaries

If the task is how the teleprompter or the pill *looks*, don't change how recording works. The F5
wiring, the capture path, the mechanics — those are a separate thing from the UI, and a look change
has no business touching them.

`site/` is live. Don't delete it.

Whatever ships publicly from here gets a private-data pass first. The bundled dictionary carries
common developer terms, not my personal entries.

## What I've decided

Accurate and raw aren't the same thing, and I've decided: raw accurate. When I retract a word
mid-sentence and say it again differently, hand over the full truth — retraction and all — so the
model sees how I got to the end of the sentence. If I cut a word off in the middle, keep the fragment
with an ellipsis — "fu…" — and carry on. Don't resolve this by accident while fixing the duplication
bug. They're different problems.

## Gotcha

This is a Mac app. You cannot verify it from localhost — a change has to be run against the real
app with the real agents and real macOS permissions before anyone claims it works. Testing a branch
build means replacing the live build so the MCP reconnects to the new version, then swapping back.
That lifecycle is not solid yet, and it has broken F5 and left two VoiceLayers running before.

> Ratified row-by-row by voice, read aloud in full, 2026-08-08. Record:
> `docs.local/GRILL-RATIFIED-2026-08-05.md` (§ FINAL RATIFIED BODY — 2026-08-08).

---

# VoiceLayer Agent Notes (operational)

## Review Guidelines

- VoiceBar is a Swift macOS menu bar app at `/Applications/VoiceBar.app`
- MCP server is the TypeScript layer: `src/mcp-server.ts`
- voice_speak is async (returns immediately), voice_ask is blocking
- One voice operation at a time — never parallelize speak/ask calls
- Build: `bash flow-bar/build-app.sh`

## Key Paths

- `src/` — TypeScript MCP server
- `flow-bar/` — Swift VoiceBar app
- `tests/` and `src/__tests__/` — run with `bun test`

## MCP Tools

| Tool | Type | Notes |
|------|------|-------|
| `voice_speak` | Async | Returns immediately, audio plays in background |
| `voice_ask` | Blocking | Waits for speak to finish, records mic, returns transcription |

## Test & Build

```bash
bun test                    # full suite (takes a few minutes; touches audio + sockets)
bash flow-bar/build-app.sh  # Build VoiceBar
```

The suite is safe on a live host **only with the preload**. `bunfig.toml` loads
`src/__tests__/setup/preload.ts` before any test module, which redirects every
VoiceLayer path — sockets, stop/cancel signals, session locks, the replay ring
buffer, the recordings archive — to `.test-tmp/<pid>/` inside the worktree, and
serves recorder spawns from a silence stub instead of the microphone. Without it
a run writes into the paths the resident VoiceBar is reading: on 2026-09-06
three of Etan's live dictations were cancelled seconds after `bun test`, and
every run deleted his replay ring buffer. Do not run with `--preload=` disabled,
and **never run real-mic tests (`VOICELAYER_TEST_REAL_MIC=1`) while someone is
dictating** — that flag is the only way a test opens the device. If the preload
is ever bypassed, mic-touching suites skip loudly rather than race the live app
(`src/__tests__/setup/live-host-guard.ts`). Unix sockets are the one thing still
under `/tmp`: macOS caps `sun_path` at 104 bytes, and test socket fixtures are
named `*-test-*.sock` so they never collide with `/tmp/voicelayer.sock`.

## PR Workflow

- `@codex review` + `@cursor @bugbot review` on every PR
- VoiceLayer is enabled for Codex Cloud reviews

## Releasing — npm publishing is AUTOMATED

- `.github/workflows/publish.yml` triggers on `push: tags: ['v*']`. Pushing the tag publishes.
- It uses **npm Trusted Publishing (OIDC)** — there is **no `NPM_TOKEN` secret and none is needed**.
  `id-token: write` lets npm exchange the GitHub OIDC token for a short-lived publish token.
- Do **not** run `npm publish` by hand, and do **not** report a release blocked on npm credentials.
  Local npm tokens on this Mac are dead and irrelevant; CI does not use them. On 2026-08-19 a worker
  burned a cycle "retrying publish" and reported a false 401 blocker to Etan because of this.
- `npm view <pkg> version` is **not** evidence your publish worked — it shows whatever is on the
  registry regardless of who put it there. Use the command's exit status and `npm view <pkg> time`.
- Formula/cask checksums must come from the **published** artifact, never a local `npm pack`:
  `npm publish` re-packs and gzip embeds a timestamp, so local bytes differ.

## Deploying to the M1 Pro (ssh host `m1`)

- **`brew` is NOT on the M1's non-interactive ssh PATH.** `ssh m1 'brew ...'` returns nothing and
  reads as "not installed". Always use `/opt/homebrew/bin/brew`. This trap produced two false
  "M1 is not brew-managed" reports on 2026-08-19, one of which reached Etan.
- **Never rsync or unzip a bundle into `/Applications` on that box.** It is brew-managed; a
  hand-placed bundle makes brew's registration and the filesystem disagree, which is what turned a
  routine cask upgrade destructive and left the M1 with no VoiceBar at all on 2026-08-19.
- Full procedure: `docs/m1-homebrew-voicebar-runbook.md`.

## BrainLayer

Use `brain_search` before reading files. VoiceLayer history is indexed.

<!-- IDENTITY: voicelayer — owned by EtanHey — voice I/O (TTS+STT) for AI coding assistants — see Etan's letter at the top of this file -->

<!-- ARCHITECTURE: key stack components, IPC socket pattern, blocking vs non-blocking tools, session booking -->
<!-- STACK: TypeScript/Bun MCP server, SwiftUI VoiceBar, Python TTS daemon, whisper.cpp/Wispr STT -->
## Stack (WHAT)
- TypeScript/Bun MCP server and CLI in `src/`
- SwiftUI macOS Voice Bar app in `flow-bar/`
- Python TTS daemon (Qwen3-TTS) plus edge-tts
- whisper.cpp or Wispr Flow STT backends

<!-- COMMANDS: bun test (run tests) | bun run src/mcp-server.ts (stdio mode) | bash scripts/migrate-to-daemon.sh (migrate all repos) | bash flow-bar/build-app.sh (build VoiceBar) -->
## Workflow (HOW)
- Start at `src/mcp-server.ts` (stdio) or `src/mcp-server-daemon.ts` (singleton daemon).
- Core runtime in `src/tts.ts`, `src/input.ts`, `src/vad.ts`, `src/stt.ts`.
- IPC uses `/tmp/voicelayer.sock` (Voice Bar is the server, MCP connects as client); protocol types in `src/socket-protocol.ts`.
- `voice_speak` is non-blocking; `voice_ask` blocks and uses Silero VAD by default.
- Keep session booking and ring buffer behavior stable (see `src/session-booking.ts`, `src/paths.ts`).
- Tests live in `src/__tests__/`; run `bun test`.

<!-- MCP-SERVERS: add new MCP server entries to .mcp.json — current servers: playwright, voicelayer-daemon (socat to /tmp/voicelayer-mcp.sock) -->
## Playwright MCP (browser automation)

- `.mcp.json` config: `{ "mcpServers": { "playwright": { "command": "npx", "args": ["@playwright/mcp@latest"] } } }`
- Provides `browser_navigate`, `browser_snapshot`, `browser_click`, etc.
- Hebrew text renders as proper Unicode in the accessibility tree (verified against he.wikipedia.org).
- Verification tests in `tests/playwright-mcp-verify.test.ts`.

<!-- PATHS: src/mcp-server.ts (entry), src/tts.ts, src/input.ts, src/vad.ts, src/stt.ts, src/session-booking.ts, src/socket-protocol.ts, src/paths.ts, flow-bar/ (SwiftUI), src/__tests__/ (tests), scripts/migrate-to-daemon.sh -->
<!-- TESTING: bun test — tests in src/__tests__/ | Playwright MCP tests in tests/playwright-mcp-verify.test.ts -->
## MCP Daemon — VoiceBar.app is the SOLE owner
- **Never install a second owner.** `com.voicelayer.mcp-daemon` is RETIRED: `launchd/install.sh`
  boots it out and deletes its plist, printing *"Retired. VoiceBar.app now owns the MCP daemon child
  process."* A second owner is the double-owner bug that took five commits to fix.
- Singleton daemon on `/tmp/voicelayer-mcp.sock` — replaces per-session `voicelayer-mcp` spawning.
- `.mcp.json` config: `{ "command": "socat", "args": ["STDIO", "UNIX-CONNECT:/tmp/voicelayer-mcp.sock"] }`
- Migration: `bash scripts/migrate-to-daemon.sh` (migrates all repos under ~/Gits).
