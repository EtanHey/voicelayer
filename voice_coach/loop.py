"""Main voice coaching conversation loop.

Uses claude CLI (Claude Code) as the LLM backend, giving the coach full
access to MCP tools (BrainLayer, VoiceLayer), skills, and the filesystem.
"""

import subprocess
from pathlib import Path

from .audio import record
from .stt import transcribe
from .tts import speak

# Voice-specific formatting rules only — coaching personality comes from
# the coachClaude skill and Claude Code's context (CLAUDE.md, MCP servers).
VOICE_FORMAT = (
    "You are responding in a voice conversation. Rules for spoken output:\n"
    "- 2-4 sentences max — this will be read aloud via TTS\n"
    "- No markdown, no bullet points, no code blocks, no lists\n"
    "- Natural spoken language, contractions are fine\n"
    "- If a topic needs detail, offer to go deeper\n"
    "- Lead with the most important thing first"
)


def _build_prompt(transcript: str, history: list[dict]) -> str:
    """Build a prompt string with conversation history for claude CLI.

    Args:
        transcript: The user's current spoken input.
        history: Prior conversation turns.

    Returns:
        Formatted prompt string.

    Raises:
        ValueError: If transcript is empty.
    """
    if not transcript or not transcript.strip():
        raise ValueError("transcript cannot be empty")

    parts = []
    for msg in history:
        prefix = "User" if msg["role"] == "user" else "Coach"
        parts.append(f"{prefix}: {msg['content']}")
    parts.append(f"User: {transcript.strip()}")
    return "\n".join(parts)


def _truncate_history(history: list[dict], max_turns: int = 10) -> list[dict]:
    """Return a new list with at most max_turns most recent messages.

    Ensures the result starts with a user message (API requirement)
    by dropping a leading assistant message if the slice would start with one.
    """
    if len(history) <= max_turns:
        return list(history)
    truncated = list(history[-max_turns:])
    if truncated and truncated[0]["role"] == "assistant":
        truncated = truncated[1:]
    return truncated


def _coach_respond(transcript: str, history: list[dict]) -> str:
    """Send transcript to claude CLI and return the response.

    Uses Claude Code's `-p` (print) mode with `--append-system-prompt`
    for voice formatting. Claude Code provides full tool access (BrainLayer,
    MCP servers, skills) that the raw Anthropic API would not have.

    Args:
        transcript: User's spoken input (already transcribed).
        history: Prior conversation turns.

    Returns:
        Coach response text.

    Raises:
        RuntimeError: If claude CLI fails.
    """
    prompt = _build_prompt(transcript, history)
    cmd = [
        "claude", "-p", prompt,
        "--output-format", "text",
        "--append-system-prompt", VOICE_FORMAT,
    ]

    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=120,
    )

    if result.returncode != 0:
        raise RuntimeError(f"claude CLI failed: {result.stderr.strip()}")

    return result.stdout.strip()


def run() -> None:
    """Start the voice coaching loop. Press Ctrl+C to exit."""
    history: list[dict] = []

    print("Voice Coach — speak when ready. Press Ctrl+C to exit.\n")

    # Greeting — seed into history so first user reply has context
    greeting = "Hey! I'm your coach. How are you feeling today?"
    print(f"Coach: {greeting}")
    try:
        speak(greeting)
    except Exception as e:
        print(f"[tts error: {e}] (greeting was printed above)")
    history.append({"role": "assistant", "content": greeting})

    while True:
        print("\nListening... (speak now, silence stops recording)")
        try:
            wav_path = record()
        except RuntimeError as e:
            print(f"[recording error: {e}]")
            continue

        try:
            transcript = transcribe(wav_path)
        except Exception as e:
            print(f"[transcription error: {e}]")
            continue
        finally:
            Path(wav_path).unlink(missing_ok=True)

        if not transcript:
            print("[no speech detected, try again]")
            continue

        print(f"You: {transcript}")

        try:
            response = _coach_respond(transcript, history)
        except Exception as e:
            print(f"[coach error: {e}]")
            continue

        # Update history
        history.append({"role": "user", "content": transcript})
        history.append({"role": "assistant", "content": response})
        history = _truncate_history(history)

        print(f"Coach: {response}\n")
        try:
            speak(response)
        except Exception as e:
            print(f"[tts error: {e}] (response was printed above)")
