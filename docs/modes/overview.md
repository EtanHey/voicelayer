# Voice Modes Guide

VoiceLayer has 2 tools: **voice_speak** (output) and **voice_ask** (input). voice_speak supports 5 modes — auto-detected from message content or set explicitly.

## Quick Reference

| Mode | Tool | Claude Speaks | You Speak | Use For |
|------|------|:---:|:---:|---------|
| [Announce](announce.md) | voice_speak | Yes | No | Status updates, notifications |
| [Brief](brief.md) | voice_speak | Yes | No | Explanations, reading back findings |
| [Consult](consult.md) | voice_speak | Yes | No | Checkpoints before actions |
| [Converse](converse.md) | voice_ask | Yes | **Yes** | Interactive Q&A, discussions |
| [Think](think.md) | voice_speak | No | No | Silent notes to a log file |

## Choosing the Right Mode

### "Claude just needs to tell me something"

Use **announce** for short updates:

> "Build complete. All tests passing."
> "Deployed to staging."
> "Found 3 issues on the checkout page."

Use **brief** for longer explanations:

> "Here's what I found in the auth module. There are three entry points: the main middleware validates JWT tokens, the second handles OAuth callbacks, and the third manages API key auth for service accounts."

The difference: announce is snappy (+10% speed), brief is slower (-10%) so you can follow along.

### "Claude should check with me first"

Use **consult** before important actions:

> "I'm about to push to main and create a PR. Want me to go ahead?"
> "The test suite has 3 failures. Should I fix them or skip for now?"

Consult is one-way — Claude speaks but doesn't record your mic. If you want to respond by voice, tell Claude to follow up with **voice_ask**.

### "We need to have a conversation"

Use **converse** for back-and-forth voice dialogue:

> **Claude:** "How does the navigation look on mobile?"
> **You:** "The hamburger menu is cut off on the right side, and the dropdown overlaps with the hero section."

This is the only mode that records your microphone. Claude speaks the question, waits for your voice response, transcribes it locally, and continues.

**Stopping a recording:** Touch `/tmp/voicelayer-stop` or wait for 5 seconds of silence.

### "Claude should take notes silently"

Use **think** for background note-taking with no audio:

> Insight: User mentioned they prefer dark mode defaults
> Red flag: No error handling in the payment flow
> Question: Should we support Safari < 16?

Think mode writes timestamped entries to `/tmp/voicelayer-thinking.md`. Useful for review sessions where Claude captures observations without interrupting the flow.

## Speech Rates

Each mode has a tuned speed:

| Mode | Default Rate | Why |
|------|:---:|-----|
| Announce | +10% | Quick updates, no need to linger |
| Brief | -10% | Longer content needs slower delivery |
| Consult | +5% | Checkpoints — slightly fast |
| Converse | +0% | Natural conversational pace |

All modes auto-slow for text longer than 300 characters.

You can override the rate per-call or globally via the `QA_VOICE_TTS_RATE` environment variable. See [Configuration](../getting-started/configuration.md).

## Stop Signal

All audio modes support an immediate stop:

```bash
touch /tmp/voicelayer-stop
```

This kills playback instantly. In converse mode, it also ends mic recording and sends whatever was captured so far for transcription.

## Session Booking

Only **converse** mode uses the microphone. To prevent conflicts when running multiple Claude Code sessions, VoiceLayer uses a lockfile (`/tmp/voicelayer-session.lock`).

- First session to call converse books the mic
- Other sessions see "line busy" and fall back to text
- Lock auto-cleans if the owning process dies
- Lock releases on session exit

See [Session Booking](../architecture/session-booking.md) for details.

## Aliases

Old `qa_voice_*` names still work as backward-compat aliases (e.g. `qa_voice_say` → announce, `qa_voice_ask` → voice_ask).
