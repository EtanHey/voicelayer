"""TTS via edge-tts — text to MP3 audio file."""

import subprocess
import tempfile
from pathlib import Path

# English voice — warm, clear for coaching
DEFAULT_VOICE = "en-US-GuyNeural"


def build_tts_command(text: str, output_path: str, voice: str = DEFAULT_VOICE) -> list[str]:
    """Build the edge-tts command for converting text to audio.

    Args:
        text: Text to speak. Must be non-empty.
        output_path: Path to write the output MP3 file.
        voice: Edge-TTS voice name.

    Returns:
        Command list suitable for subprocess.run().

    Raises:
        ValueError: If text is empty or whitespace-only.
    """
    if not text or not text.strip():
        raise ValueError("text cannot be empty")

    return [
        "edge-tts",
        "--voice", voice,
        "--text", text.strip(),
        "--write-media", output_path,
    ]


def speak(text: str, voice: str = DEFAULT_VOICE) -> None:
    """Speak text via edge-tts, blocking until audio finishes playing.

    Args:
        text: Text to speak. Empty text is silently ignored.
        voice: Edge-TTS voice name.
    """
    if not text or not text.strip():
        return

    with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as f:
        output_path = f.name

    try:
        cmd = build_tts_command(text, output_path, voice=voice)
        subprocess.run(cmd, check=True, capture_output=True, timeout=30)
        subprocess.run(["afplay", output_path], check=True, timeout=120)
    finally:
        Path(output_path).unlink(missing_ok=True)
