# What is VoiceLayer?

**VoiceLayer lets Claude talk to you and listen.**

When you use [Claude Code](https://docs.anthropic.com/en/docs/claude-code), everything happens through text — you type, Claude types back. VoiceLayer adds voice to that conversation.

## What Can It Do?

- **Claude speaks to you** through your speakers — status updates, explanations, questions
- **You speak back** through your microphone — Claude transcribes what you said and continues working
- **Everything stays local** — your voice is transcribed on your machine, nothing leaves your computer

## Real Examples

### QA Testing a Website
You're reviewing a client's website with Claude. Instead of typing descriptions of what you see:

> **Claude (voice):** "How does the checkout page look on mobile?"
>
> **You (voice):** "The payment form is cut off on the right. And the submit button is hidden behind the keyboard."
>
> Claude records this, moves to the next page, and keeps testing.

### Hands-Free Code Review
You're walking through code changes while Claude takes notes:

> **Claude (voice):** "I found three changes in the auth module. Want me to walk through them?"
>
> **You (voice):** "Yes, start with the middleware changes."

### Background Notifications
Claude finishes a long task while you're reading docs in another window:

> **Claude (voice):** "Build complete. 47 tests passing, 2 skipped."

No need to switch back to the terminal to check.

## How It Works (Simply)

1. You add VoiceLayer to Claude Code (one line in a config file)
2. Claude gains 5 new voice tools — announce, brief, consult, converse, and think
3. When Claude wants to speak, it calls the voice tool
4. When Claude needs your input, it speaks a question, records your answer, and reads the transcription

The entire flow happens in your terminal. No browser, no app, no account needed.

## What You Need

- **A Mac or Linux computer** with speakers and a microphone
- **Claude Code** installed
- **Bun** (a JavaScript runtime — one command to install)
- **sox** (for microphone recording — one command to install)
- **edge-tts** (for text-to-speech — one command to install)
- **whisper.cpp** (for speech-to-text — optional but recommended for fully local operation)

Total setup time: about 5 minutes. See the [Quick Start](getting-started/quickstart.md) guide.

## Is It Free?

Yes. VoiceLayer is open source (MIT license). All voice processing runs locally on your machine. The only optional cloud component is Wispr Flow for speech-to-text, which requires an API key — but the default whisper.cpp backend is fully local and free.
