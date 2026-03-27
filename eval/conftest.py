"""Pytest fixtures for STT eval tests."""

import os
import subprocess
import tempfile

import pytest


@pytest.fixture
def temp_dir():
    """Provide a temporary directory that is cleaned up after the test."""
    with tempfile.TemporaryDirectory() as d:
        yield d


@pytest.fixture
def sample_wav(temp_dir):
    """Generate a minimal valid WAV file for testing."""
    wav_path = os.path.join(temp_dir, "test.wav")
    _write_silent_wav(wav_path, duration_sec=1.0)
    return wav_path


def _write_silent_wav(path: str, duration_sec: float = 1.0, sample_rate: int = 16000):
    """Write a silent WAV file with correct headers."""
    import struct

    num_samples = int(sample_rate * duration_sec)
    data_size = num_samples * 2  # 16-bit = 2 bytes per sample
    file_size = 36 + data_size

    with open(path, "wb") as f:
        f.write(b"RIFF")
        f.write(struct.pack("<I", file_size))
        f.write(b"WAVE")
        f.write(b"fmt ")
        f.write(struct.pack("<I", 16))       # chunk size
        f.write(struct.pack("<H", 1))        # PCM
        f.write(struct.pack("<H", 1))        # mono
        f.write(struct.pack("<I", sample_rate))
        f.write(struct.pack("<I", sample_rate * 2))  # byte rate
        f.write(struct.pack("<H", 2))        # block align
        f.write(struct.pack("<H", 16))       # bits per sample
        f.write(b"data")
        f.write(struct.pack("<I", data_size))
        f.write(b"\x00" * data_size)         # silence
