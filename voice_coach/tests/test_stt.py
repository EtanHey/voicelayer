"""Tests for voice_coach.stt — whisper-cli output parsing and binary detection."""

import shutil

import pytest
from voice_coach.stt import parse_whisper_output, find_whisper_cli


def test_parse_returns_clean_text():
    """Normal transcription output is returned stripped."""
    raw = "  I just woke up feeling tired.  \n"
    assert parse_whisper_output(raw) == "I just woke up feeling tired."


def test_parse_strips_blank_audio_token():
    """[BLANK_AUDIO] token must be removed and empty string returned."""
    assert parse_whisper_output("[BLANK_AUDIO]") == ""


def test_parse_strips_whisper_timestamps():
    """Lines with timestamp annotations are stripped."""
    raw = "[00:00.000 --> 00:02.500]  Hello there"
    assert parse_whisper_output(raw) == "Hello there"


def test_parse_strips_multiple_timestamp_lines():
    """Multiple timestamp lines are joined into clean text."""
    raw = (
        "[00:00.000 --> 00:01.000]  First sentence.\n"
        "[00:01.000 --> 00:02.000]  Second sentence."
    )
    result = parse_whisper_output(raw)
    assert "First sentence." in result
    assert "Second sentence." in result
    assert "[" not in result


def test_parse_returns_empty_for_noise_only():
    """Noise-only output like (Music) returns empty string."""
    assert parse_whisper_output("(Music)") == ""
    assert parse_whisper_output("(Applause)") == ""
    assert parse_whisper_output("( music )") == ""


def test_parse_handles_empty_input():
    """Empty input returns empty string, no error."""
    assert parse_whisper_output("") == ""
    assert parse_whisper_output("   \n  ") == ""


def test_find_whisper_cli_returns_string():
    """find_whisper_cli must return a non-empty path string."""
    path = find_whisper_cli()
    assert isinstance(path, str)
    assert len(path) > 0


def test_find_whisper_cli_finds_installed_binary():
    """On this machine, whisper-cli should be findable."""
    # This test is environment-specific but validates the detection logic
    path = find_whisper_cli()
    assert "whisper" in path
