"""Tests for voice_coach.tts — edge-tts command building."""

import pytest
from voice_coach.tts import build_tts_command, DEFAULT_VOICE


def test_build_command_uses_edge_tts():
    """Command must invoke edge-tts."""
    cmd = build_tts_command("Hello coach.", output_path="/tmp/out.mp3")
    assert cmd[0] == "edge-tts"


def test_build_command_includes_text():
    """Command must include the text to speak."""
    cmd = build_tts_command("Good morning!", output_path="/tmp/out.mp3")
    cmd_str = " ".join(cmd)
    assert "Good morning!" in cmd_str


def test_build_command_includes_voice():
    """Command must include --voice flag with a voice name."""
    cmd = build_tts_command("Hello.", output_path="/tmp/out.mp3")
    assert "--voice" in cmd
    voice_idx = cmd.index("--voice")
    assert len(cmd[voice_idx + 1]) > 0


def test_build_command_includes_output_path():
    """Command must include --write-media flag with the output path."""
    cmd = build_tts_command("Test.", output_path="/tmp/coach_out.mp3")
    assert "--write-media" in cmd
    path_idx = cmd.index("--write-media")
    assert cmd[path_idx + 1] == "/tmp/coach_out.mp3"


def test_build_command_empty_text_raises():
    """Empty text must raise ValueError."""
    with pytest.raises(ValueError):
        build_tts_command("", output_path="/tmp/out.mp3")
    with pytest.raises(ValueError):
        build_tts_command("  ", output_path="/tmp/out.mp3")


def test_default_voice_is_defined():
    """DEFAULT_VOICE must be a non-empty string."""
    assert isinstance(DEFAULT_VOICE, str)
    assert len(DEFAULT_VOICE) > 0
