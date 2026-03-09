"""Tests for voice_coach.loop — coach response and conversation logic."""

from unittest.mock import MagicMock, patch

import pytest

from voice_coach.loop import _coach_respond, _MODEL, _truncate_history


def test_coach_respond_uses_system_prompt():
    """_coach_respond must pass SYSTEM_PROMPT as the system parameter."""
    mock_client = MagicMock()
    mock_client.messages.create.return_value.content = [MagicMock(text="Got it.")]

    with patch("voice_coach.loop._get_client", return_value=mock_client):
        _coach_respond("I slept 7 hours.", [])

    call_kwargs = mock_client.messages.create.call_args[1]
    assert "system" in call_kwargs
    assert "coach" in call_kwargs["system"].lower()


def test_coach_respond_includes_history():
    """_coach_respond must include conversation history in the messages."""
    mock_client = MagicMock()
    mock_client.messages.create.return_value.content = [MagicMock(text="Good.")]
    history = [
        {"role": "user", "content": "Hi"},
        {"role": "assistant", "content": "Hello!"},
    ]

    with patch("voice_coach.loop._get_client", return_value=mock_client):
        _coach_respond("How am I doing?", history)

    call_kwargs = mock_client.messages.create.call_args[1]
    messages = call_kwargs["messages"]
    assert len(messages) == 3  # 2 history + 1 new
    assert messages[-1]["content"] == "How am I doing?"


def test_coach_respond_returns_text():
    """_coach_respond must return the response text string."""
    mock_client = MagicMock()
    mock_client.messages.create.return_value.content = [
        MagicMock(text="Nice work on the sleep target.")
    ]

    with patch("voice_coach.loop._get_client", return_value=mock_client):
        result = _coach_respond("I woke at 7:30.", [])

    assert result == "Nice work on the sleep target."


def test_truncate_history_keeps_last_n():
    """History longer than max_turns is truncated to keep the most recent."""
    history = [{"role": "user", "content": str(i)} for i in range(20)]
    result = _truncate_history(history, max_turns=10)
    assert len(result) == 10
    assert result[-1]["content"] == "19"


def test_truncate_history_noop_when_short():
    """History shorter than max_turns is returned unchanged."""
    history = [{"role": "user", "content": "hi"}]
    result = _truncate_history(history, max_turns=10)
    assert len(result) == 1


def test_truncate_history_returns_new_list():
    """Truncation must not mutate the original list."""
    history = [{"role": "user", "content": str(i)} for i in range(20)]
    original_len = len(history)
    _truncate_history(history, max_turns=10)
    assert len(history) == original_len


def test_truncate_history_starts_with_user_role():
    """Truncated history must always start with a user message."""
    # 11 messages — naive slice would start with assistant
    history = []
    for i in range(6):
        history.append({"role": "user", "content": f"u{i}"})
        if i < 5:
            history.append({"role": "assistant", "content": f"a{i}"})
    # 11 messages: u0 a0 u1 a1 u2 a2 u3 a3 u4 a4 u5
    result = _truncate_history(history, max_turns=10)
    assert result[0]["role"] == "user"


def test_truncate_history_always_even_pairs():
    """Truncated history length must be even (user/assistant pairs)."""
    history = []
    for i in range(7):
        history.append({"role": "user", "content": f"u{i}"})
        history.append({"role": "assistant", "content": f"a{i}"})
    # 14 messages, max_turns=10 → should return 10 (5 pairs)
    result = _truncate_history(history, max_turns=10)
    assert len(result) % 2 == 0
    assert result[0]["role"] == "user"
