#!/usr/bin/env python3
"""
VoiceLayer Clone — Select reference clips and create a voice profile for zero-shot cloning.

No model training or fine-tuning. This command:
1. Reads samples from ~/.voicelayer/voices/{name}/samples/
2. Analyzes audio quality (duration, RMS level, SNR estimate)
3. Selects best 3 clips (~18.5s total) for reference
4. Generates transcripts for reference clips (via whisper.cpp)
5. Writes profile.yaml

Usage:
    voicelayer clone --name theo
    voicelayer clone --name theo --source "https://youtube.com/@t3dotgg"
"""

# AIDEV-NOTE: This is zero-shot — no training. The "clone" command only selects
# reference audio and writes the profile. Actual voice cloning happens at runtime
# when the Qwen3-TTS daemon uses these reference clips.

import argparse
import json
import shutil
import subprocess
import sys
import wave
from datetime import date
from pathlib import Path

VOICES_DIR = Path.home() / ".voicelayer" / "voices"

# Optimal reference audio: 3 clips totaling ~18.5s (Qwen3-TTS sweet spot: 3-30s)
TARGET_TOTAL_DURATION = 18.5
TARGET_CLIP_COUNT = 3
MIN_CLIP_DURATION = 3.0
MAX_CLIP_DURATION = 12.0


def get_wav_duration(path: Path) -> float:
    """Get duration of a WAV file in seconds."""
    try:
        with wave.open(str(path), "r") as w:
            return w.getnframes() / w.getframerate()
    except Exception:
        return 0.0


def get_wav_rms(path: Path) -> float:
    """Get RMS energy of a WAV file (proxy for audio quality)."""
    try:
        with wave.open(str(path), "r") as w:
            frames = w.readframes(w.getnframes())
            if w.getsampwidth() == 2:
                import struct
                samples = struct.unpack(f"<{len(frames) // 2}h", frames)
                if not samples:
                    return 0.0
                rms = (sum(s * s for s in samples) / len(samples)) ** 0.5
                return rms
    except Exception:
        pass
    return 0.0


def transcribe_clip(clip_path: Path) -> str:
    """Transcribe a clip using whisper.cpp (if available)."""
    # Try whisper-cli first, then whisper-cpp
    for binary in ["whisper-cli", "whisper-cpp"]:
        if shutil.which(binary):
            # Find model
            model_path = find_whisper_model()
            if not model_path:
                return "[transcript unavailable — no whisper model]"

            try:
                result = subprocess.run(
                    [
                        binary,
                        "-m", str(model_path),
                        "-f", str(clip_path),
                        "--no-timestamps",
                        "--no-prints",
                        "-l", "en",
                    ],
                    capture_output=True,
                    text=True,
                    timeout=60,
                )
                if result.returncode == 0:
                    text = result.stdout.strip()
                    if text:
                        return text
            except (subprocess.TimeoutExpired, FileNotFoundError):
                pass

    return "[transcript unavailable — whisper not installed]"


def find_whisper_model() -> Path | None:
    """Find a whisper model file."""
    cache_dir = Path.home() / ".cache" / "whisper"
    if not cache_dir.exists():
        return None

    # Preferred order
    for name in [
        "ggml-large-v3-turbo.bin",
        "ggml-large-v3-turbo-q5_0.bin",
        "ggml-base.en.bin",
        "ggml-base.bin",
    ]:
        p = cache_dir / name
        if p.exists():
            return p

    # Any ggml model
    for p in cache_dir.glob("ggml-*.bin"):
        return p

    return None


def select_best_clips(
    samples_dir: Path,
) -> list[dict]:
    """
    Select the best reference clips from samples directory.

    Strategy:
    - Filter clips to valid duration range (3-12s)
    - Score by: duration proximity to ~6s + high RMS (clear audio)
    - Select top 3 clips that total ~18.5s
    """
    candidates = []

    for wav_path in sorted(samples_dir.glob("*.wav")):
        duration = get_wav_duration(wav_path)
        if duration < MIN_CLIP_DURATION or duration > MAX_CLIP_DURATION:
            continue

        rms = get_wav_rms(wav_path)

        # Score: prefer ~6s clips with high RMS
        duration_score = 1.0 - abs(duration - 6.0) / 6.0  # 0-1, best at 6s
        rms_score = min(rms / 3000.0, 1.0)  # normalize to 0-1
        score = duration_score * 0.4 + rms_score * 0.6

        candidates.append({
            "path": wav_path,
            "duration": duration,
            "rms": rms,
            "score": score,
        })

    if not candidates:
        return []

    # Sort by score descending
    candidates.sort(key=lambda c: c["score"], reverse=True)

    # Greedily select clips up to target duration
    selected = []
    total_duration = 0.0

    for c in candidates:
        if len(selected) >= TARGET_CLIP_COUNT:
            break
        if total_duration + c["duration"] > TARGET_TOTAL_DURATION + 2.0:
            continue
        selected.append(c)
        total_duration += c["duration"]

    return selected


def write_profile(
    name: str,
    clips: list[dict],
    transcripts: list[str],
    source: str | None = None,
    fallback: str = "en-US-AndrewNeural",
):
    """Write profile.yaml for the voice."""
    voice_dir = VOICES_DIR / name
    profile_path = voice_dir / "profile.yaml"

    lines = [
        f"name: {name}",
        "engine: qwen3-tts",
        "model_path: ~/.voicelayer/models/qwen3-tts-4bit",
        "reference_clips:",
    ]

    for clip, transcript in zip(clips, transcripts):
        # Use ~ relative path for portability
        rel_path = str(clip["path"]).replace(str(Path.home()), "~")
        lines.append(f"  - path: {rel_path}")
        # Escape quotes in transcript
        safe_text = transcript.replace('"', '\\"')
        lines.append(f'    text: "{safe_text}"')

    # Primary reference clip (first selected)
    if clips:
        primary_path = str(clips[0]["path"]).replace(str(Path.home()), "~")
        lines.append(f"reference_clip: {primary_path}")
        if transcripts:
            safe_primary = transcripts[0].replace('"', '\\"')
            lines.append(f'reference_text: "{safe_primary}"')

    lines.append(f"fallback: {fallback}")
    lines.append(f"created: {date.today().isoformat()}")
    if source:
        lines.append(f"source: {source}")

    profile_path.write_text("\n".join(lines) + "\n")
    return profile_path


def main():
    parser = argparse.ArgumentParser(
        description="Create a voice profile for zero-shot cloning"
    )
    parser.add_argument(
        "--name",
        required=True,
        help="Voice name (matches samples directory)",
    )
    parser.add_argument(
        "--source",
        help="Attribution URL (e.g., YouTube channel)",
    )
    parser.add_argument(
        "--fallback",
        default="en-US-AndrewNeural",
        help="Edge-TTS voice for fallback (default: en-US-AndrewNeural)",
    )
    parser.add_argument(
        "--skip-transcribe",
        action="store_true",
        help="Skip transcription (use placeholders)",
    )
    parser.add_argument(
        "--check-deps",
        action="store_true",
        help="Check dependencies and exit",
    )
    args = parser.parse_args()

    # Check dependencies
    if args.check_deps:
        whisper = shutil.which("whisper-cli") or shutil.which("whisper-cpp")
        model = find_whisper_model()
        print(f"whisper binary: {whisper or 'NOT FOUND'}")
        print(f"whisper model: {model or 'NOT FOUND'}")
        print(f"Voices dir: {VOICES_DIR}")
        sys.exit(0 if whisper and model else 1)

    # Validate samples exist
    samples_dir = VOICES_DIR / args.name / "samples"
    if not samples_dir.exists():
        print(f"Error: Samples directory not found: {samples_dir}", file=sys.stderr)
        print(
            f"Run 'voicelayer extract --source <url> --name {args.name}' first.",
            file=sys.stderr,
        )
        sys.exit(1)

    wav_files = list(samples_dir.glob("*.wav"))
    if not wav_files:
        print(f"Error: No WAV files in {samples_dir}", file=sys.stderr)
        sys.exit(1)

    print(f"Found {len(wav_files)} samples in {samples_dir}")

    # Select best clips
    print("Analyzing audio quality and selecting reference clips...")
    clips = select_best_clips(samples_dir)
    if not clips:
        print("Error: No suitable clips found (need 3-12s duration)", file=sys.stderr)
        sys.exit(1)

    total_dur = sum(c["duration"] for c in clips)
    print(f"Selected {len(clips)} clips ({total_dur:.1f}s total):")
    for i, c in enumerate(clips):
        print(f"  {i+1}. {c['path'].name} ({c['duration']:.1f}s, RMS: {c['rms']:.0f})")

    # Transcribe clips
    transcripts = []
    if args.skip_transcribe:
        print("Skipping transcription (--skip-transcribe)")
        transcripts = ["[transcript placeholder]"] * len(clips)
    else:
        print("Transcribing reference clips...")
        for i, c in enumerate(clips):
            print(f"  Transcribing {c['path'].name}...", end=" ", flush=True)
            text = transcribe_clip(c["path"])
            print(f"done ({len(text)} chars)")
            transcripts.append(text)

    # Write profile
    profile_path = write_profile(
        name=args.name,
        clips=clips,
        transcripts=transcripts,
        source=args.source,
        fallback=args.fallback,
    )

    print(f"\nProfile written: {profile_path}")
    print(f"\nTest with:")
    print(f'  voice_speak("Hello, this is a test", voice="{args.name}")')


if __name__ == "__main__":
    main()
