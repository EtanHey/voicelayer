"""Tests for voice_coach.loop — claude CLI integration and conversation logic."""

from unittest.mock import MagicMock, patch
import subprocess

import pytest

from voice_coach.loop import (
    _coach_respond,
    _build_prompt,
    _truncate_history,
    VOICE_FORMAT,
)


# --- prompt building ---


def test_build_prompt_single_turn():
    """Single user turn produces just the transcript."""
    prompt = _build_prompt("I slept 7 hours.", [])
    assert "I slept 7 hours." in prompt


def test_build_prompt_includes_history():
    """History turns are included before the new message."""
    history = [
        {"role": "user", "content": "Hi"},
        {"role": "assistant", "content": "Hello!"},
    ]
    prompt = _build_prompt("How am I doing?", history)
    assert "Hi" in prompt
    assert "Hello!" in prompt
    assert "How am I doing?" in prompt
    # New message must come after history
    assert prompt.index("Hi") < prompt.index("How am I doing?")


def test_build_prompt_empty_raises():
    """Empty transcript must raise ValueError."""
    with pytest.raises(ValueError):
        _build_prompt("", [])
    with pytest.raises(ValueError):
        _build_prompt("   ", [])


# --- claude CLI integration ---


def test_coach_respond_calls_claude_cli():
    """_coach_respond must invoke 'claude' via subprocess, not anthropic SDK."""
    mock_result = MagicMock()
    mock_result.returncode = 0
    mock_result.stdout = "Nice work on the sleep target."

    with patch("voice_coach.loop.subprocess.run", return_value=mock_result) as mock_run:
        result = _coach_respond("I woke at 7:30.", [])

    # Must call claude CLI, not anthropic
    cmd = mock_run.call_args[0][0]
    assert cmd[0] == "claude"
    assert "-p" in cmd
    assert result == "Nice work on the sleep target."


def test_coach_respond_passes_output_format_text():
    """claude CLI must be called with --output-format text."""
    mock_result = MagicMock()
    mock_result.returncode = 0
    mock_result.stdout = "Response."

    with patch("voice_coach.loop.subprocess.run", return_value=mock_result) as mock_run:
        _coach_respond("test", [])

    cmd = mock_run.call_args[0][0]
    assert "--output-format" in cmd
    fmt_idx = cmd.index("--output-format")
    assert cmd[fmt_idx + 1] == "text"


def test_coach_respond_includes_voice_format():
    """claude CLI must include voice format instructions via --append-system-prompt."""
    mock_result = MagicMock()
    mock_result.returncode = 0
    mock_result.stdout = "Response."

    with patch("voice_coach.loop.subprocess.run", return_value=mock_result) as mock_run:
        _coach_respond("test", [])

    cmd = mock_run.call_args[0][0]
    assert "--append-system-prompt" in cmd


def test_coach_respond_raises_on_cli_failure():
    """Non-zero exit from claude CLI must raise RuntimeError."""
    mock_result = MagicMock()
    mock_result.returncode = 1
    mock_result.stderr = "API error"

    with patch("voice_coach.loop.subprocess.run", return_value=mock_result):
        with pytest.raises(RuntimeError, match="claude"):
            _coach_respond("test", [])


def test_voice_format_mentions_spoken():
    """VOICE_FORMAT must mention spoken/voice/TTS format constraints."""
    fmt_lower = VOICE_FORMAT.lower()
    assert any(w in fmt_lower for w in ["spoken", "voice", "tts", "aloud"])


# --- history truncation ---


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
    history = []
    for i in range(6):
        history.append({"role": "user", "content": f"u{i}"})
        if i < 5:
            history.append({"role": "assistant", "content": f"a{i}"})
    result = _truncate_history(history, max_turns=10)
    assert result[0]["role"] == "user"


def test_truncate_history_always_even_pairs():
    """Truncated history length must be even (user/assistant pairs)."""
    history = []
    for i in range(7):
        history.append({"role": "user", "content": f"u{i}"})
        history.append({"role": "assistant", "content": f"a{i}"})
    result = _truncate_history(history, max_turns=10)
    assert len(result) % 2 == 0
    assert result[0]["role"] == "user"
