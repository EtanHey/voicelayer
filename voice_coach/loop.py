"""Main voice coaching conversation loop."""

from pathlib import Path

import anthropic

from .audio import record
from .coach import SYSTEM_PROMPT, build_messages
from .stt import transcribe
from .tts import speak

_client = anthropic.Anthropic()
_MODEL = "claude-sonnet-4-6"


def _truncate_history(history: list[dict], max_turns: int = 10) -> list[dict]:
    """Return a new list with at most max_turns most recent messages."""
    if len(history) <= max_turns:
        return list(history)
    return list(history[-max_turns:])


def _coach_respond(user_text: str, history: list[dict]) -> str:
    """Send user_text to Claude with coach context, return response text."""
    messages = build_messages(user_text, history=history)
    response = _client.messages.create(
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
        speak(response)
