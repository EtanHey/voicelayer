"""STT via whisper-cli — audio file to text transcript."""

import os
import re
import shutil
import subprocess
from pathlib import Path

DEFAULT_MODEL = str(Path.home() / ".cache/whisper/ggml-large-v3-turbo.bin")

# Candidate binary names, checked in order (matches VoiceLayer TS detection)
_WHISPER_CANDIDATES = ["whisper-cli", "whisper-cpp"]


def find_whisper_cli() -> str:
    """Find the whisper-cli binary, checking PATH and common install locations.

    Returns:
        Path to the whisper-cli binary.

    Raises:
        RuntimeError: If no whisper binary is found.
    """
    env_override = os.environ.get("VOICE_COACH_WHISPER_CLI")
    if env_override:
        return env_override

    for name in _WHISPER_CANDIDATES:
        path = shutil.which(name)
        if path:
            return path

    raise RuntimeError(
        "whisper-cli not found. Install via: brew install whisper-cpp"
    )

# Patterns that indicate noise or silence, not real speech
_NOISE_PATTERNS = re.compile(
    r"^\s*[\(\[]\s*(?:music|applause|laughter|noise|silence|inaudible|crosstalk)[^\)\]]*[\)\]]\s*$",
    re.IGNORECASE,
)

# Whisper timestamp lines: [00:00.000 --> 00:02.500]
_TIMESTAMP_LINE = re.compile(r"^\[[\d:.]+\s*-->\s*[\d:.]+\]\s*")

# [BLANK_AUDIO] token
_BLANK_AUDIO = re.compile(r"\[BLANK_AUDIO\]", re.IGNORECASE)


def parse_whisper_output(raw: str) -> str:
    """Parse raw whisper-cli stdout into clean transcription text.

    Handles:
    - [BLANK_AUDIO] tokens → empty string
    - Timestamp prefixes [00:00.000 --> 00:02.500] → stripped
    - Noise-only lines like (Music), (Applause) → empty string
    - Whitespace normalization

    Args:
        raw: Raw stdout from whisper-cli.

    Returns:
        Clean transcript string, or "" if no speech detected.
    """
    if not raw or not raw.strip():
        return ""

    # Remove [BLANK_AUDIO] entirely
    text = _BLANK_AUDIO.sub("", raw)

    lines = []
    for line in text.splitlines():
        # Strip timestamp prefix
        line = _TIMESTAMP_LINE.sub("", line)
        line = line.strip()
        if not line:
            continue
        # Skip noise-only lines
        if _NOISE_PATTERNS.match(line):
            continue
        lines.append(line)

    return " ".join(lines).strip()


def transcribe(audio_path: str, model: str = DEFAULT_MODEL) -> str:
    """Transcribe an audio file using whisper-cli.

    Args:
        audio_path: Path to WAV file to transcribe.
        model: Path to GGML model file.

    Returns:
        Transcribed text, or "" if no speech detected.

    Raises:
        RuntimeError: If whisper-cli fails.
    """
    whisper_bin = find_whisper_cli()
    result = subprocess.run(
        [whisper_bin, "-m", model, "-f", audio_path, "--no-timestamps", "-np"],
        capture_output=True,
        text=True,
        timeout=60,
    )
    if result.returncode != 0:
        raise RuntimeError(f"whisper-cli failed: {result.stderr.strip()}")
    return parse_whisper_output(result.stdout)
