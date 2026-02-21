# Voice Modes Overview

VoiceLayer provides 5 distinct voice modes, each designed for a specific interaction pattern. Choosing the right mode determines whether the agent speaks, listens, or just takes notes.

## Mode Comparison

| Mode | Direction | Blocking | Mic Required | Session Booking |
|------|-----------|----------|-------------|-----------------|
| [Announce](announce.md) | Agent -> User | No | No | No |
| [Brief](brief.md) | Agent -> User | No | No | No |
| [Consult](consult.md) | Agent -> User | No | No | No |
| [Converse](converse.md) | Agent <-> User | **Yes** | **Yes** | **Yes** |
| [Think](think.md) | Agent -> File | No | No | No |

## When to Use Each Mode

### Announce
Short status updates that don't need a response.

> "Build complete. 47 tests passing."

### Brief
Longer explanations where the agent reads back findings or decisions.

> "Here's what I found: the auth module has three entry points. The main one is in middleware.ts which validates JWT tokens and attaches the user object. The second is..."

### Consult
Checkpoint before a potentially destructive or important action. The agent speaks, and the user *might* want to respond — but no mic recording happens.

> "I'm about to push to the feature branch and create a PR. Want to review the diff first?"

If the user does want to respond, follow up with a `converse` call.

### Converse
Full bidirectional voice Q&A. The agent speaks a question, records the user's voice response, transcribes it, and returns the text.

> Agent: "How does the navigation look on mobile?"
> User: "The hamburger menu is cut off on the right side, and the dropdown overlaps the hero section."

### Think
Silent note-taking to a markdown log file. No audio at all — the agent captures insights, flags, or questions that the user can glance at in a split-screen editor.

## Speech Rate by Mode

Each mode has a tuned default speech rate:

| Mode | Rate | Why |
|------|------|-----|
| Announce | +10% | Quick updates, no need to linger |
| Brief | -10% | Longer content needs slower delivery |
| Consult | +5% | Checkpoints — slightly fast |
| Converse | +0% | Natural conversational pace |

All modes auto-slow for long text (300+ characters).

## Stop Signal

All TTS modes (announce, brief, consult, converse) support the stop signal:

```bash
touch /tmp/voicelayer-stop
```

This immediately kills audio playback. In converse mode, it also ends mic recording.

## Backward Compatibility

Two aliases are provided for older agent code:

| Alias | Maps To |
|-------|---------|
| `qa_voice_say` | `qa_voice_announce` |
| `qa_voice_ask` | `qa_voice_converse` |
