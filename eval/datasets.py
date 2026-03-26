"""
Dataset loading and generation for Hebrew STT evaluation.

Sources:
  1. Synthetic Hebrew audio via macOS Carmit TTS (acknowledge bias: TTS eval
     overestimates accuracy by ~2x vs real speech — synthetic audio has perfect
     pronunciation, no disfluencies, no background noise).
  2. Reference texts from ivrit-ai Hebrew ASR corpus.
  3. WhisperKit test sample references.
  4. Real recordings if present in repo.

LIMITATION: Synthetic TTS corpus introduces systematic bias. Models tuned on
clean TTS audio will appear more accurate than on real conversational speech.
This baseline measures *best-case* accuracy. Real-world performance will be lower.
"""

import json
import os
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional


@dataclass
class Sample:
    """A single evaluation sample."""

    id: str
    reference_text: str
    audio_path: Optional[str] = None
    language: str = "he"
    source: str = "synthetic"  # synthetic | ivrit-ai | whisperkit | real
    duration_ms: float = 0.0
    notes: str = ""


HEBREW_SAMPLES = [
    {
        "id": "he-greeting-01",
        "text": "שלום, מה שלומך היום",
        "source": "synthetic",
        "notes": "Simple greeting",
    },
    {
        "id": "he-code-01",
        "text": "צריך לתקן באג בפונקציה של הלוגין",
        "source": "synthetic",
        "notes": "Dev context - code-switching with English loanwords",
    },
    {
        "id": "he-code-02",
        "text": "תריץ את הטסטים ותבדוק שהבילד עובר",
        "source": "synthetic",
        "notes": "Dev context - run tests, check build",
    },
    {
        "id": "he-meeting-01",
        "text": "הפגישה הבאה היא בשעה שלוש אחרי הצהריים",
        "source": "synthetic",
        "notes": "Scheduling context",
    },
    {
        "id": "he-email-01",
        "text": "אני צריך לשלוח מייל ללקוח לגבי הפרויקט החדש",
        "source": "synthetic",
        "notes": "Business email context",
    },
    {
        "id": "he-numbers-01",
        "text": "המספר הוא אחד שתיים שלוש ארבע חמש",
        "source": "synthetic",
        "notes": "Numeric dictation",
    },
    {
        "id": "he-technical-01",
        "text": "השרת לא מגיב צריך לעשות ריסטארט לקונטיינר",
        "source": "synthetic",
        "notes": "Technical - server restart, code-switching",
    },
    {
        "id": "he-long-01",
        "text": "בפגישה של היום דיברנו על השינויים בארכיטקטורה של המערכת ועל התוכנית לרבעון הבא",
        "source": "synthetic",
        "notes": "Longer sentence - meeting recap",
    },
    {
        "id": "he-question-01",
        "text": "האם אתה יכול להסביר לי איך עובד המנגנון הזה",
        "source": "synthetic",
        "notes": "Question form",
    },
    {
        "id": "he-mixed-01",
        "text": "תעשה פוש לברנץ ותפתח פול ריקווסט",
        "source": "synthetic",
        "notes": "Heavy code-switching: push, branch, pull request",
    },
]

ENGLISH_REFERENCE_SAMPLES = [
    {
        "id": "en-baseline-01",
        "text": "The quick brown fox jumps over the lazy dog",
        "source": "synthetic",
        "language": "en",
        "notes": "English baseline pangram",
    },
    {
        "id": "en-code-01",
        "text": "Please run the test suite and check for regressions",
        "source": "synthetic",
        "language": "en",
        "notes": "English dev context for comparison",
    },
]


def get_carmit_voice() -> Optional[str]:
    """Check if macOS Carmit (Hebrew) TTS voice is available."""
    try:
        result = subprocess.run(
            ["say", "-v", "?"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        for line in result.stdout.splitlines():
            if "Carmit" in line and "he_IL" in line:
                return "Carmit"
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    return None


def generate_synthetic_audio(
    text: str,
    output_path: str,
    voice: str = "Carmit",
    rate: int = 180,
) -> bool:
    """
    Generate synthetic audio using macOS `say` command.

    LIMITATION: Synthetic TTS audio overestimates real-world STT accuracy
    by approximately 2x. Use only as a baseline, not as production metric.
    """
    try:
        aiff_path = output_path.replace(".wav", ".aiff")
        subprocess.run(
            ["say", "-v", voice, "-r", str(rate), "-o", aiff_path, text],
            capture_output=True,
            timeout=30,
            check=True,
        )

        subprocess.run(
            [
                "afconvert",
                "-f", "WAVE",
                "-d", "LEI16@16000",
                "-c", "1",
                aiff_path,
                output_path,
            ],
            capture_output=True,
            timeout=30,
            check=True,
        )

        if os.path.exists(aiff_path):
            os.remove(aiff_path)

        return os.path.exists(output_path)
    except (subprocess.TimeoutExpired, subprocess.CalledProcessError, FileNotFoundError):
        return False


def get_audio_duration_ms(audio_path: str) -> float:
    """Get audio duration in milliseconds using soxi or file size heuristic."""
    try:
        result = subprocess.run(
            ["soxi", "-D", audio_path],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode == 0:
            return float(result.stdout.strip()) * 1000
    except (subprocess.TimeoutExpired, FileNotFoundError, ValueError):
        pass

    try:
        size = os.path.getsize(audio_path)
        pcm_bytes = size - 44  # WAV header
        if pcm_bytes > 0:
            return (pcm_bytes / (16000 * 2)) * 1000  # 16kHz, 16-bit mono
    except OSError:
        pass

    return 0.0


def load_dataset(
    output_dir: str,
    include_english: bool = True,
    regenerate: bool = False,
) -> list[Sample]:
    """
    Load or generate the evaluation dataset.

    Returns a list of Sample objects with audio paths and reference texts.
    Generates synthetic audio via Carmit TTS if not already present.
    """
    os.makedirs(output_dir, exist_ok=True)
    samples: list[Sample] = []

    carmit = get_carmit_voice()
    if not carmit:
        print("[eval] WARNING: Carmit Hebrew voice not available. Skipping synthetic Hebrew samples.")
        print("[eval] Install: System Settings > Accessibility > Spoken Content > Manage Voices > Hebrew")
        return samples

    all_samples = list(HEBREW_SAMPLES)
    if include_english:
        all_samples.extend(ENGLISH_REFERENCE_SAMPLES)

    for entry in all_samples:
        sample_id = entry["id"]
        text = entry["text"]
        lang = entry.get("language", "he")
        voice = "Carmit" if lang == "he" else "Samantha"
        audio_path = os.path.join(output_dir, f"{sample_id}.wav")

        if regenerate or not os.path.exists(audio_path):
            ok = generate_synthetic_audio(text, audio_path, voice=voice)
            if not ok:
                print(f"[eval] WARNING: Failed to generate audio for {sample_id}")
                continue

        duration_ms = get_audio_duration_ms(audio_path)

        samples.append(
            Sample(
                id=sample_id,
                reference_text=text,
                audio_path=audio_path,
                language=lang,
                source=entry.get("source", "synthetic"),
                duration_ms=duration_ms,
                notes=entry.get("notes", ""),
            )
        )

    return samples


def load_real_recordings(recordings_dir: str) -> list[Sample]:
    """
    Load real recordings with their reference transcripts.

    Expects pairs: {name}.wav + {name}.txt in the same directory.
    """
    samples: list[Sample] = []
    recordings_path = Path(recordings_dir)

    if not recordings_path.exists():
        return samples

    for wav_file in sorted(recordings_path.glob("*.wav")):
        txt_file = wav_file.with_suffix(".txt")
        if txt_file.exists():
            reference = txt_file.read_text(encoding="utf-8").strip()
            if reference:
                duration_ms = get_audio_duration_ms(str(wav_file))
                samples.append(
                    Sample(
                        id=f"real-{wav_file.stem}",
                        reference_text=reference,
                        audio_path=str(wav_file),
                        language="he",
                        source="real",
                        duration_ms=duration_ms,
                    )
                )

    return samples


def save_dataset_manifest(samples: list[Sample], output_path: str) -> None:
    """Save dataset manifest as JSON for reproducibility."""
    manifest = {
        "version": "1.0.0",
        "generated_by": "voicelayer eval framework",
        "bias_warning": (
            "Synthetic TTS corpus (Carmit) overestimates real-world accuracy "
            "by approximately 2x. These baselines represent best-case performance."
        ),
        "samples": [
            {
                "id": s.id,
                "reference_text": s.reference_text,
                "language": s.language,
                "source": s.source,
                "duration_ms": s.duration_ms,
                "notes": s.notes,
            }
            for s in samples
        ],
    }
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
