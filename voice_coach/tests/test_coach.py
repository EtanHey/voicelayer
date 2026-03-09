"""Tests for voice_coach.coach — system prompt and message building."""

import pytest
from voice_coach.coach import SYSTEM_PROMPT, build_messages


def test_system_prompt_includes_coach_identity():
    """System prompt must establish coachClaude's identity and health focus."""
    assert "coach" in SYSTEM_PROMPT.lower()
    assert len(SYSTEM_PROMPT) > 100


def test_system_prompt_includes_voice_context():
    """System prompt must mention voice/conversational format for brevity."""
    prompt_lower = SYSTEM_PROMPT.lower()
    assert any(word in prompt_lower for word in ["voice", "spoken", "concise", "brief"])


def test_build_messages_single_turn():
    """Single user input builds a list with one human message."""
    messages = build_messages("I just woke up feeling tired.")
    assert len(messages) == 1
    assert messages[0]["role"] == "user"
    assert messages[0]["content"] == "I just woke up feeling tired."


def test_build_messages_with_history():
    """History is prepended before the new user message."""
    history = [
        {"role": "user", "content": "Hi"},
        {"role": "assistant", "content": "Hello! How can I help?"},
    ]
    messages = build_messages("Had 2 coffees today.", history=history)
    assert len(messages) == 3
    assert messages[0]["role"] == "user"
    assert messages[1]["role"] == "assistant"
    assert messages[2]["content"] == "Had 2 coffees today."


def test_build_messages_does_not_mutate_history():
    """build_messages must not mutate the passed history list."""
    history = [{"role": "user", "content": "Hi"}]
    original_len = len(history)
    build_messages("New message.", history=history)
    assert len(history) == original_len


def test_build_messages_empty_input_raises():
    """Empty or whitespace-only input must raise ValueError."""
    with pytest.raises(ValueError):
        build_messages("")
    with pytest.raises(ValueError):
        build_messages("   ")
