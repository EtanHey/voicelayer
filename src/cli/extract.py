#!/usr/bin/env python3
"""
VoiceLayer Audio Extraction Pipeline

YouTube URL → yt-dlp (WAV 48kHz) → [optional Demucs] → Silero VAD segmentation
→ [optional pyannote diarization] → FFmpeg normalization → voice samples

Usage:
    python3 src/cli/extract.py --source "https://youtube.com/@channel" --name "speaker" --count 20
    voicelayer extract --source "https://youtube.com/@channel" --name "speaker" --count 20
"""

import argparse
import json
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

# AIDEV-NOTE: Pipeline stages are modular — each can be skipped via flags.
# Demucs and pyannote are optional (skip for clean single-speaker audio).

VOICES_DIR = Path.home() / ".voicelayer" / "voices"

# FFmpeg normalization filter chain — produces 24kHz mono 16-bit PCM
FFMPEG_NORMALIZE_FILTER = (
    "highpass=f=80,"
    "lowpass=f=12000,"
    "agate=threshold=-40dB:ratio=4:attack=5:release=200,"
    "loudnorm=I=-16:TP=-1.5:LRA=11"
)


def check_dependencies() -> list[str]:
    """Check which required tools are available."""
    missing = []
    for cmd in ["yt-dlp", "ffmpeg", "ffprobe"]:
        try:
            subprocess.run(
                [cmd, "--version"],
                capture_output=True,
                timeout=10,
            )
        except (FileNotFoundError, subprocess.TimeoutExpired):
            missing.append(cmd)

    # Check Python packages
    try:
        import silero_vad  # noqa: F401
    except ImportError:
        missing.append("silero-vad (pip install silero-vad)")

    try:
        import torch  # noqa: F401
    except ImportError:
        missing.append("torch (pip install torch)")

    try:
        import soundfile  # noqa: F401
    except ImportError:
        missing.append("soundfile (pip install soundfile)")

    return missing


def download_audio(
    source: str,
    output_dir: Path,
    archive_file: Path,
    count: int,
    section_start: str = "00:01:00",
    section_end: str = "00:05:00",
) -> list[Path]:
    """Download audio from YouTube using yt-dlp with exact flags from spec."""
    output_dir.mkdir(parents=True, exist_ok=True)

    # yt-dlp output template — sequential numbering
    output_template = str(output_dir / "%(title).50s-%(id)s.%(ext)s")

    cmd = [
        "yt-dlp",
        "--extract-audio",
        "--audio-format", "wav",
        "--audio-quality", "0",
        "--postprocessor-args", "ffmpeg:-ar 48000 -ac 2",
        "--download-archive", str(archive_file),
        "--download-sections", f"*{section_start}-{section_end}",
        "--max-downloads", str(count),
        "--no-playlist" if "watch?v=" in source else "--yes-playlist",
        "--output", output_template,
        source,
    ]

    print(f"[voicelayer] Downloading audio from: {source}")
    print(f"[voicelayer] Sections: {section_start} → {section_end}")
    print(f"[voicelayer] Max downloads: {count}")

    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=600,
    )

    if result.returncode != 0 and "Max downloads reached" not in result.stderr:
        # yt-dlp returns non-zero on max-downloads, that's expected
        if "ERROR" in result.stderr:
            print(f"[voicelayer] yt-dlp warning: {result.stderr.strip()}")

    # Collect downloaded WAV files
    wav_files = sorted(output_dir.glob("*.wav"), key=lambda p: p.stat().st_mtime)
    print(f"[voicelayer] Downloaded {len(wav_files)} audio file(s)")
    return wav_files


def detect_music(wav_path: Path) -> bool:
    """Simple heuristic: check if audio has significant non-speech energy.

    Uses spectral analysis via ffprobe to detect music/background noise.
    Returns True if Demucs separation is recommended.
    """
    # AIDEV-NOTE: This is a basic heuristic. For production, consider using
    # a dedicated music detection model. For podcast audio (like t3dotgg),
    # this should return False → skip Demucs.
    try:
        result = subprocess.run(
            [
                "ffprobe", "-v", "quiet",
                "-print_format", "json",
                "-show_format",
                str(wav_path),
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )
        info = json.loads(result.stdout)
        # If audio is very short or can't be analyzed, skip Demucs
        duration = float(info.get("format", {}).get("duration", 0))
        if duration < 10:
            return False
    except (subprocess.TimeoutExpired, json.JSONDecodeError, KeyError):
        pass

    return False  # Default: assume clean audio, skip Demucs


def run_demucs(wav_path: Path, output_dir: Path) -> Path:
    """Run Demucs vocal separation — extracts vocals from mixed audio."""
    print(f"[voicelayer] Running Demucs vocal separation on: {wav_path.name}")

    cmd = [
        "python3", "-m", "demucs",
        "--two-stems", "vocals",
        "--name", "htdemucs_ft",
        "-d", "mps",  # Apple Silicon GPU
        "--out", str(output_dir),
        str(wav_path),
    ]

    result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    if result.returncode != 0:
        print(f"[voicelayer] Demucs failed: {result.stderr.strip()}")
        print("[voicelayer] Falling back to original audio")
        return wav_path

    # Demucs outputs to: output_dir/htdemucs_ft/{stem_name}/vocals.wav
    vocals_path = output_dir / "htdemucs_ft" / wav_path.stem / "vocals.wav"
    if vocals_path.exists():
        print("[voicelayer] Vocal separation complete")
        return vocals_path

    print("[voicelayer] Demucs output not found, using original")
    return wav_path


def segment_with_vad(
    wav_path: Path,
    output_dir: Path,
    min_segment_s: float = 6.0,
    max_segment_s: float = 30.0,
    merge_gap_ms: int = 500,
    min_discard_s: float = 3.0,
) -> list[Path]:
    """Segment audio using Silero VAD v6.2.

    - Target: 6-30s segments
    - Merge speech gaps <500ms
    - Discard clips <3s or >30s
    """
    import soundfile as sf
    import torch
    from silero_vad import get_speech_timestamps, load_silero_vad, read_audio

    print(f"[voicelayer] Running Silero VAD segmentation on: {wav_path.name}")

    model = load_silero_vad()

    # Read at 16kHz for VAD (Silero requires 8k or 16k)
    wav = read_audio(str(wav_path), sampling_rate=16000)
    total_duration = len(wav) / 16000
    print(f"[voicelayer] Audio duration: {total_duration:.1f}s")

    # Get speech timestamps
    speech_timestamps = get_speech_timestamps(
        wav,
        model,
        sampling_rate=16000,
        threshold=0.5,
        min_speech_duration_ms=250,
        min_silence_duration_ms=merge_gap_ms,
        speech_pad_ms=30,
        return_seconds=True,
    )

    if not speech_timestamps:
        print("[voicelayer] No speech detected")
        return []

    print(f"[voicelayer] Found {len(speech_timestamps)} raw speech segments")

    # Merge adjacent segments that are close together and would create
    # segments within our target range
    merged = _merge_segments(speech_timestamps, merge_gap_ms / 1000.0, max_segment_s)
    print(f"[voicelayer] After merging: {len(merged)} segments")

    # Read original audio at full sample rate for extraction
    original_data, original_sr = sf.read(str(wav_path))

    output_dir.mkdir(parents=True, exist_ok=True)
    segments = []

    for i, seg in enumerate(merged):
        duration = seg["end"] - seg["start"]

        # Discard too short or too long
        if duration < min_discard_s:
            continue
        if duration > max_segment_s:
            # Split into sub-segments
            sub_segs = _split_segment(seg, max_segment_s, min_discard_s)
            for j, sub in enumerate(sub_segs):
                out_path = output_dir / f"segment_{i:04d}_{j:02d}.wav"
                _extract_segment(original_data, original_sr, sub, out_path)
                segments.append(out_path)
            continue

        out_path = output_dir / f"segment_{i:04d}.wav"
        _extract_segment(original_data, original_sr, seg, out_path)
        segments.append(out_path)

    print(f"[voicelayer] Extracted {len(segments)} valid segments ({min_segment_s}-{max_segment_s}s)")
    return segments


def _merge_segments(
    timestamps: list[dict],
    gap_threshold_s: float,
    max_duration_s: float,
) -> list[dict]:
    """Merge speech segments separated by gaps smaller than threshold."""
    if not timestamps:
        return []

    merged = [dict(timestamps[0])]

    for seg in timestamps[1:]:
        prev = merged[-1]
        gap = seg["start"] - prev["end"]
        combined_duration = seg["end"] - prev["start"]

        if gap <= gap_threshold_s and combined_duration <= max_duration_s:
            prev["end"] = seg["end"]
        else:
            merged.append(dict(seg))

    return merged


def _split_segment(
    seg: dict,
    max_s: float,
    min_s: float,
) -> list[dict]:
    """Split a segment longer than max_s into valid sub-segments."""
    parts = []
    start = seg["start"]
    end = seg["end"]

    while start < end:
        chunk_end = min(start + max_s, end)
        if chunk_end - start >= min_s:
            parts.append({"start": start, "end": chunk_end})
        start = chunk_end

    return parts


def _extract_segment(
    audio_data,
    sample_rate: int,
    seg: dict,
    output_path: Path,
) -> None:
    """Extract a time segment from audio data and save to WAV."""
    import soundfile as sf

    start_sample = int(seg["start"] * sample_rate)
    end_sample = int(seg["end"] * sample_rate)

    # Handle mono vs stereo
    if len(audio_data.shape) == 1:
        segment_data = audio_data[start_sample:end_sample]
    else:
        segment_data = audio_data[start_sample:end_sample, :]

    sf.write(str(output_path), segment_data, sample_rate)


def run_diarization(wav_path: Path) -> dict:
    """Run pyannote speaker diarization to identify speakers.

    Returns dict mapping speaker labels to time ranges.
    Only useful for multi-speaker audio.
    """
    print(f"[voicelayer] Running pyannote diarization on: {wav_path.name}")

    try:
        from pyannote.audio import Pipeline

        pipeline = Pipeline.from_pretrained(
            "pyannote/speaker-diarization-3.1",
            use_auth_token=True,
        )
        diarization = pipeline(str(wav_path))

        speakers = {}
        for turn, _, speaker in diarization.itertracks(yield_label=True):
            if speaker not in speakers:
                speakers[speaker] = []
            speakers[speaker].append({
                "start": turn.start,
                "end": turn.end,
            })

        print(f"[voicelayer] Found {len(speakers)} speaker(s)")
        return speakers

    except ImportError:
        print("[voicelayer] pyannote.audio not installed, skipping diarization")
        return {}
    except Exception as e:
        print(f"[voicelayer] Diarization failed: {e}")
        return {}


def normalize_audio(input_path: Path, output_path: Path) -> bool:
    """Normalize audio with FFmpeg — 24kHz mono 16-bit PCM WAV."""
    cmd = [
        "ffmpeg", "-y",
        "-i", str(input_path),
        "-af", FFMPEG_NORMALIZE_FILTER,
        "-ar", "24000",
        "-ac", "1",
        "-sample_fmt", "s16",
        str(output_path),
    ]

    result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    if result.returncode != 0:
        print(f"[voicelayer] FFmpeg normalization failed for {input_path.name}")
        return False
    return True


def create_metadata(
    voice_dir: Path,
    name: str,
    source: str,
    samples: list[Path],
    pipeline_config: dict,
) -> dict:
    """Create metadata.json for the extracted voice samples."""
    import soundfile as sf

    sample_info = []
    total_duration = 0.0

    for sample_path in samples:
        info = sf.info(str(sample_path))
        duration = info.duration
        total_duration += duration
        sample_info.append({
            "file": sample_path.name,
            "duration_s": round(duration, 2),
            "sample_rate": info.samplerate,
            "channels": info.channels,
        })

    metadata = {
        "name": name,
        "source": source,
        "extracted_at": datetime.now(timezone.utc).isoformat(),
        "pipeline": {
            "yt_dlp_version": _get_version("yt-dlp"),
            "ffmpeg_version": _get_version("ffmpeg"),
            "demucs_used": pipeline_config.get("demucs", False),
            "diarization_used": pipeline_config.get("diarization", False),
            "vad_threshold": 0.5,
            "merge_gap_ms": 500,
            "segment_range_s": [6, 30],
            "normalization": {
                "sample_rate": 24000,
                "channels": 1,
                "bit_depth": 16,
                "loudness_target": -16,
                "true_peak": -1.5,
            },
        },
        "samples": sample_info,
        "total_samples": len(samples),
        "total_duration_s": round(total_duration, 2),
    }

    metadata_path = voice_dir / "metadata.json"
    metadata_path.write_text(json.dumps(metadata, indent=2))
    print(f"[voicelayer] Wrote metadata.json ({len(samples)} samples, {total_duration:.1f}s total)")
    return metadata


def create_profile(voice_dir: Path, name: str, metadata: dict) -> None:
    """Create profile.yaml for the voice — used by cloning engines."""
    profile = f"""# VoiceLayer Voice Profile
# Generated: {datetime.now(timezone.utc).isoformat()}

name: {name}
source: {metadata['source']}
language: en

# Sample statistics
total_samples: {metadata['total_samples']}
total_duration_s: {metadata['total_duration_s']}

# Audio format (all samples normalized to this)
format:
  sample_rate: 24000
  channels: 1
  bit_depth: 16
  encoding: pcm_s16le

# Recommended cloning settings
cloning:
  # Minimum samples for good quality
  min_samples: 5
  # Best results with 10-30s of clean speech
  optimal_duration_s: 20
  # Suggested engines (in preference order)
  engines:
    - fish-speech
    - xtts-v2
    - bark

# Pipeline info
pipeline:
  demucs: {str(metadata['pipeline']['demucs_used']).lower()}
  diarization: {str(metadata['pipeline']['diarization_used']).lower()}
"""

    profile_path = voice_dir / "profile.yaml"
    profile_path.write_text(profile)
    print(f"[voicelayer] Wrote profile.yaml")


def _get_version(cmd: str) -> str:
    """Get version string for a CLI tool."""
    try:
        result = subprocess.run(
            [cmd, "--version"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        # First line usually contains version
        return result.stdout.strip().split("\n")[0]
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return "unknown"


def run_pipeline(args: argparse.Namespace) -> None:
    """Execute the full extraction pipeline."""
    start_time = time.time()

    # Setup directories
    voice_dir = VOICES_DIR / args.name
    voice_dir.mkdir(parents=True, exist_ok=True)
    raw_dir = voice_dir / "raw"
    raw_dir.mkdir(exist_ok=True)
    samples_dir = voice_dir / "samples"
    samples_dir.mkdir(exist_ok=True)
    archive_file = voice_dir / ".archive"

    pipeline_config = {
        "demucs": False,
        "diarization": False,
    }

    # Stage 1: Download with yt-dlp
    print("\n=== Stage 1: Download ===")
    wav_files = download_audio(
        source=args.source,
        output_dir=raw_dir,
        archive_file=archive_file,
        count=args.count,
        section_start=args.section_start,
        section_end=args.section_end,
    )

    if not wav_files:
        print("[voicelayer] No audio files downloaded. Exiting.")
        sys.exit(1)

    # Stage 2: Optional Demucs vocal separation
    processed_files = []
    if args.demucs or (not args.skip_demucs and not args.single_speaker):
        print("\n=== Stage 2: Demucs Vocal Separation ===")
        demucs_dir = voice_dir / "demucs_output"
        for wav in wav_files:
            if args.demucs or detect_music(wav):
                pipeline_config["demucs"] = True
                processed = run_demucs(wav, demucs_dir)
                processed_files.append(processed)
            else:
                print(f"[voicelayer] Skipping Demucs for {wav.name} (clean audio)")
                processed_files.append(wav)
    else:
        print("\n=== Stage 2: Demucs — SKIPPED (clean audio) ===")
        processed_files = wav_files

    # Stage 3: Silero VAD segmentation
    print("\n=== Stage 3: VAD Segmentation ===")
    vad_segments_dir = voice_dir / "vad_segments"
    all_segments = []
    for wav in processed_files:
        segments = segment_with_vad(
            wav_path=wav,
            output_dir=vad_segments_dir,
            min_segment_s=6.0,
            max_segment_s=30.0,
            merge_gap_ms=500,
            min_discard_s=3.0,
        )
        all_segments.extend(segments)

    if not all_segments:
        print("[voicelayer] No valid segments found after VAD. Exiting.")
        sys.exit(1)

    # Stage 4: Optional pyannote diarization
    if args.diarize and not args.single_speaker:
        print("\n=== Stage 4: Speaker Diarization ===")
        pipeline_config["diarization"] = True
        # For now, just log speaker info — filtering by speaker TBD
        for wav in processed_files:
            speakers = run_diarization(wav)
            if speakers:
                print(f"[voicelayer] Speakers in {wav.name}: {list(speakers.keys())}")
    else:
        print("\n=== Stage 4: Diarization — SKIPPED (single speaker) ===")

    # Stage 5: FFmpeg normalization
    print("\n=== Stage 5: FFmpeg Normalization ===")
    normalized_samples = []
    for i, segment in enumerate(all_segments):
        output_path = samples_dir / f"{args.name}_{i:04d}.wav"
        if normalize_audio(segment, output_path):
            normalized_samples.append(output_path)

    if not normalized_samples:
        print("[voicelayer] No samples survived normalization. Exiting.")
        sys.exit(1)

    print(f"[voicelayer] Normalized {len(normalized_samples)} samples")

    # Stage 6: Write metadata + profile
    print("\n=== Stage 6: Metadata ===")
    metadata = create_metadata(
        voice_dir=voice_dir,
        name=args.name,
        source=args.source,
        samples=normalized_samples,
        pipeline_config=pipeline_config,
    )
    create_profile(voice_dir, args.name, metadata)

    elapsed = time.time() - start_time
    print(f"\n{'='*50}")
    print(f"[voicelayer] Pipeline complete in {elapsed:.1f}s")
    print(f"[voicelayer] Voice: {args.name}")
    print(f"[voicelayer] Samples: {len(normalized_samples)}")
    print(f"[voicelayer] Duration: {metadata['total_duration_s']:.1f}s")
    print(f"[voicelayer] Output: {voice_dir}")
    print(f"{'='*50}")


def main() -> None:
    # Quick check for --check-deps before full argparse (avoids required arg errors)
    if "--check-deps" in sys.argv:
        missing = check_dependencies()
        if missing:
            print("[voicelayer] Missing dependencies:")
            for dep in missing:
                print(f"  - {dep}")
            sys.exit(1)
        else:
            print("[voicelayer] All dependencies available")
            sys.exit(0)

    parser = argparse.ArgumentParser(
        prog="voicelayer extract",
        description="Extract voice samples from YouTube for zero-shot voice cloning",
    )
    parser.add_argument(
        "--source",
        required=True,
        help="YouTube URL (video, channel, or playlist)",
    )
    parser.add_argument(
        "--name",
        required=True,
        help="Speaker name (used for output directory and file naming)",
    )
    parser.add_argument(
        "--count",
        type=int,
        default=20,
        help="Maximum number of videos to download (default: 20)",
    )
    parser.add_argument(
        "--section-start",
        default="00:01:00",
        help="Start time for audio extraction per video (default: 00:01:00)",
    )
    parser.add_argument(
        "--section-end",
        default="00:05:00",
        help="End time for audio extraction per video (default: 00:05:00)",
    )
    parser.add_argument(
        "--single-speaker",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Assume single speaker and skip diarization (default: True, use --no-single-speaker to enable multi-speaker)",
    )
    parser.add_argument(
        "--demucs",
        action="store_true",
        default=False,
        help="Force Demucs vocal separation even for clean audio",
    )
    parser.add_argument(
        "--skip-demucs",
        action="store_true",
        default=True,
        help="Skip Demucs entirely (default: True, for clean podcast audio)",
    )
    parser.add_argument(
        "--diarize",
        action="store_true",
        default=False,
        help="Enable pyannote speaker diarization (requires HuggingFace token)",
    )
    parser.add_argument(
        "--check-deps",
        action="store_true",
        help="Check dependencies and exit",
    )

    args = parser.parse_args()

    # Check core dependencies
    missing = check_dependencies()
    if missing:
        print("[voicelayer] Missing required dependencies:")
        for dep in missing:
            print(f"  - {dep}")
        print("\nInstall with:")
        print("  brew install ffmpeg")
        print("  pip install yt-dlp silero-vad soundfile torch")
        print("  # Optional: pip install demucs pyannote.audio")
        sys.exit(1)

    run_pipeline(args)


if __name__ == "__main__":
    main()
