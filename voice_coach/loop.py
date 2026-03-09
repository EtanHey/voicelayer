"""Main voice coaching conversation loop."""

import os
from pathlib import Path

import anthropic

from .audio import record
from .coach import SYSTEM_PROMPT, build_messages
from .stt import transcribe
from .tts import speak

_client: anthropic.Anthropic | None = None
_MODEL = os.getenv("VOICE_COACH_MODEL", "claude-sonnet-4-6")


def _get_client() -> anthropic.Anthropic:
    """Lazy-init the Anthropic client (avoids import-time crash if key missing)."""
    global _client
    if _client is None:
        _client = anthropic.Anthropic()
    return _client


def _truncate_history(history: list[dict], max_turns: int = 10) -> list[dict]:
    """Return a new list with at most max_turns most recent messages.

    Ensures the result starts with a user message (Anthropic API requirement)
    by dropping a leading assistant message if the slice would start with one.
    """
    if len(history) <= max_turns:
        return list(history)
    truncated = list(history[-max_turns:])
    # Ensure first message is role=user (API requirement)
    if truncated and truncated[0]["role"] == "assistant":
        truncated = truncated[1:]
    return truncated


def _coach_respond(user_text: str, history: list[dict]) -> str:
    """Send user_text to Claude with coach context, return response text."""
    messages = build_messages(user_text, history=history)
    client = _get_client()
    response = client.messages.create(
        model=_MODEL,
        max_tokens=300,
        system=SYSTEM_PROMPT,
        messages=messages,
    )
    return response.content[0].text


def run() -> None:
    """Start the voice coaching loop. Press Ctrl+C to exit."""
    history: list[dict] = []

    print("Voice Coach — speak when ready. Press Ctrl+C to exit.\n")

    # Greeting
    greeting = "Hey! I'm your coach. How are you feeling today?"
    print(f"Coach: {greeting}")
    speak(greeting)

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
