"""Audio recording via sox/rec."""

import subprocess
import tempfile
from pathlib import Path


def record(max_silence_secs: float = 2.5, sample_rate: int = 16000) -> str:
    """Record audio from the mic until silence, return path to WAV file.

    Uses sox `rec` with silence detection. The caller is responsible for
    deleting the returned file.

    Args:
        max_silence_secs: Stop recording after this many seconds of silence.
        sample_rate: Sample rate for the WAV file (16kHz for whisper).

    Returns:
        Path to the recorded WAV file.

    Raises:
        RuntimeError: If recording fails.
    """
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        output_path = f.name

    # rec with silence detection:
    # silence 1 0.1 3% 1 {secs}s 3%
    # = start after 0.1s above 3% noise floor, stop after N seconds below 3%
    cmd = [
        "rec",
        "-q",           # quiet
        "-r", str(sample_rate),
        "-c", "1",      # mono
        output_path,
        "silence",
        "1", "0.1", "3%",                           # start detecting
        "1", f"{max_silence_secs}s", "3%",           # stop on silence
    ]

    result = subprocess.run(cmd, capture_output=True, timeout=300)
    if result.returncode != 0:
        Path(output_path).unlink(missing_ok=True)
        raise RuntimeError(f"rec failed: {result.stderr.decode().strip()}")

    return output_path
