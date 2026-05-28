#!/usr/bin/env python3
"""
Two-stage speech bakeoff harness for VoiceSDK.

Stage 1 selects base engines:
  - STT: whisper.cpp large-v3-turbo baseline vs challenger command hooks.
  - TTS: edge-tts fallback vs Kokoro/MLX candidate command hook.

Stage 2 evaluates voice identity layers only after a Stage-1 TTS base wins:
  - existing Theo F5-TTS MLX assets
  - Qwen3-TTS daemon profile path

The harness is intentionally measurement-first. Missing engines are reported as
unverified/unavailable instead of guessed.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Iterable, Sequence

from metrics import compute_cer, compute_wer


PROJECT_ROOT = Path(__file__).resolve().parents[1]
FIXTURE_PATH = PROJECT_ROOT / "eval" / "fixtures" / "hebrew_english_dev_phrases.json"
DEFAULT_WHISPER_MODEL = Path.home() / ".cache" / "whisper" / "ggml-large-v3-turbo.bin"
VOICE_ROOT = Path.home() / ".voicelayer" / "voices"
VOICELAYER_MODELS = Path.home() / ".voicelayer" / "models"


@dataclass(frozen=True)
class DevPhraseSample:
    id: str
    text: str
    language_set: str
    expected_terms: tuple[str, ...] = ()


@dataclass
class CandidateStatus:
    stage: str
    kind: str
    name: str
    role: str
    available: bool
    evidence: str
    metric_status: str = "unverified"
    notes: list[str] = field(default_factory=list)


@dataclass
class STTTextMetrics:
    sample_id: str
    wer: float
    cer: float
    repeated_tail_rate: float
    expected_term_hit_rate: float
    metric_status: str = "measured"


@dataclass
class TTSLatencyMetrics:
    candidate: str
    text_to_first_audio_ms: float | None
    synth_duration_ms: float | None
    playback_complete: bool | None
    metric_status: str
    evidence: str


def load_dev_phrase_samples(path: Path = FIXTURE_PATH) -> list[DevPhraseSample]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    samples: list[DevPhraseSample] = []
    for phrase_set in payload.get("sets", []):
        set_id = phrase_set["id"]
        for sample in phrase_set.get("samples", []):
            samples.append(
                DevPhraseSample(
                    id=sample["id"],
                    text=sample["text"],
                    language_set=set_id,
                    expected_terms=tuple(sample.get("expected_terms", [])),
                )
            )
    return samples


def repeated_tail_rate(text: str, max_tail_words: int = 6) -> float:
    words = [word.strip(".,!?;:").casefold() for word in text.split() if word.strip()]
    if len(words) < 4:
        return 0.0

    repeated = 0
    checks = 0
    for size in range(2, min(max_tail_words, len(words) // 2) + 1):
        checks += 1
        if words[-size:] == words[-(size * 2) : -size]:
            repeated += 1
    return repeated / checks if checks else 0.0


def expected_term_hit_rate(hypothesis: str, expected_terms: Sequence[str]) -> float:
    if not expected_terms:
        return 1.0
    normalized = hypothesis.casefold()
    hits = sum(1 for term in expected_terms if term.casefold() in normalized)
    return hits / len(expected_terms)


def compute_stt_text_metrics(sample: DevPhraseSample, hypothesis: str) -> STTTextMetrics:
    return STTTextMetrics(
        sample_id=sample.id,
        wer=compute_wer(sample.text, hypothesis),
        cer=compute_cer(sample.text, hypothesis),
        repeated_tail_rate=repeated_tail_rate(hypothesis),
        expected_term_hit_rate=expected_term_hit_rate(hypothesis, sample.expected_terms),
    )


def candidate_statuses() -> list[CandidateStatus]:
    statuses: list[CandidateStatus] = []

    whisper_binary = shutil.which("whisper-cli") or shutil.which("whisper-cpp")
    statuses.append(
        CandidateStatus(
            stage="stage-1-base-selection",
            kind="stt",
            name="whisper.cpp large-v3-turbo",
            role="confirmed-baseline-primary",
            available=bool(whisper_binary and DEFAULT_WHISPER_MODEL.exists()),
            evidence=(
                f"binary={whisper_binary or 'missing'}; "
                f"model={DEFAULT_WHISPER_MODEL if DEFAULT_WHISPER_MODEL.exists() else 'missing'}"
            ),
            notes=["Challengers must beat this baseline on both English-heavy and mixed Hebrew-English sets."],
        )
    )

    for name, env_name in [
        ("Parakeet TDT", "VOICELAYER_BAKEOFF_STT_PARAKEET_CMD"),
        ("WhisperKit", "VOICELAYER_BAKEOFF_STT_WHISPERKIT_CMD"),
        ("Distil-Whisper", "VOICELAYER_BAKEOFF_STT_DISTIL_WHISPER_CMD"),
    ]:
        command = os.environ.get(env_name)
        statuses.append(
            CandidateStatus(
                stage="stage-1-base-selection",
                kind="stt",
                name=name,
                role="challenger",
                available=bool(command),
                evidence=f"{env_name}={'set' if command else 'unset'}",
                notes=["Set the command hook to run a live challenger benchmark."],
            )
        )

    edge_binary = shutil.which("edge-tts")
    statuses.append(
        CandidateStatus(
            stage="stage-1-base-selection",
            kind="tts",
            name="edge-tts",
            role="current-fallback-baseline",
            available=bool(edge_binary),
            evidence=f"binary={edge_binary or 'missing'}",
            notes=["Kokoro must beat this on latency/flakiness without unacceptable quality before default cutover."],
        )
    )

    kokoro_command = os.environ.get("VOICELAYER_BAKEOFF_TTS_KOKORO_CMD")
    statuses.append(
        CandidateStatus(
            stage="stage-1-base-selection",
            kind="tts",
            name="Kokoro-82M/MLX",
            role="local-candidate",
            available=bool(kokoro_command),
            evidence=f"VOICELAYER_BAKEOFF_TTS_KOKORO_CMD={'set' if kokoro_command else 'unset'}",
            notes=["Model-card latency numbers are cited only; set the command hook for local measurements."],
        )
    )

    theo_profile = VOICE_ROOT / "theo" / "profile.yaml"
    f5_python = Path.home() / ".voicelayer" / "venv" / "bin" / "python3"
    statuses.append(
        CandidateStatus(
            stage="stage-2-voice-layer",
            kind="voice-layer",
            name="Theo F5-TTS MLX",
            role="voice-plugin-candidate",
            available=theo_profile.exists() and f5_python.exists(),
            evidence=f"profile={theo_profile if theo_profile.exists() else 'missing'}; python={f5_python if f5_python.exists() else 'missing'}",
            notes=["Evaluate only on top of the winning Stage-1 TTS base."],
        )
    )

    qwen_command = os.environ.get("VOICELAYER_BAKEOFF_TTS_QWEN3_CMD")
    statuses.append(
        CandidateStatus(
            stage="stage-2-voice-layer",
            kind="voice-layer",
            name="Qwen3-TTS zero-shot/daemon",
            role="voice-plugin-candidate",
            available=bool(qwen_command),
            evidence=f"VOICELAYER_BAKEOFF_TTS_QWEN3_CMD={'set' if qwen_command else 'unset'}; model_dir={VOICELAYER_MODELS if VOICELAYER_MODELS.exists() else 'missing'}",
            notes=["The old ~/.voicelayer/models assumption is intentionally verified and may be missing."],
        )
    )

    return statuses


def run_tts_command(candidate: str, command: Sequence[str], text: str, output_path: Path) -> TTSLatencyMetrics:
    start = time.perf_counter()
    proc = subprocess.run(
        [*command, "--text", text, "--output", str(output_path)],
        capture_output=True,
        text=True,
        timeout=120,
    )
    elapsed_ms = (time.perf_counter() - start) * 1000
    first_audio_ms = elapsed_ms if output_path.exists() and output_path.stat().st_size > 0 else None
    return TTSLatencyMetrics(
        candidate=candidate,
        text_to_first_audio_ms=first_audio_ms,
        synth_duration_ms=elapsed_ms if proc.returncode == 0 else None,
        playback_complete=None,
        metric_status="measured" if proc.returncode == 0 and first_audio_ms is not None else "unverified",
        evidence=f"exit={proc.returncode}; stderr={proc.stderr[-200:]}",
    )


def summarize_statuses(statuses: Iterable[CandidateStatus]) -> dict:
    by_stage: dict[str, list[dict]] = {}
    for status in statuses:
        by_stage.setdefault(status.stage, []).append(asdict(status))
    return {
        "version": "1.0.0",
        "fixture": str(FIXTURE_PATH),
        "dev_phrase_samples": len(load_dev_phrase_samples()),
        "stages": by_stage,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="VoiceSDK two-stage speech bakeoff harness")
    parser.add_argument("--list-candidates", action="store_true", help="Print candidate availability JSON")
    parser.add_argument("--fixture", default=str(FIXTURE_PATH), help="Dev phrase fixture path")
    args = parser.parse_args()

    if args.fixture:
        load_dev_phrase_samples(Path(args.fixture))

    if args.list_candidates:
        print(json.dumps(summarize_statuses(candidate_statuses()), ensure_ascii=False, indent=2))
        return 0

    parser.print_help()
    return 0


if __name__ == "__main__":
    sys.exit(main())
