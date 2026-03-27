"""
STT evaluation metrics — WER, CER, and latency measurements.

Uses jiwer (community standard for ASR evaluation, used by ivrit-ai).
"""

import time
from dataclasses import dataclass, field
from typing import Optional

import jiwer


@dataclass
class TranscriptionResult:
    """Result from a single STT transcription."""

    reference: str
    hypothesis: str
    backend: str
    sample_id: str
    latency_ms: float = 0.0
    audio_duration_ms: float = 0.0
    language: str = "he"
    error: Optional[str] = None


@dataclass
class MetricResult:
    """Computed metrics for a single transcription pair."""

    sample_id: str
    backend: str
    wer: float
    cer: float
    latency_ms: float
    audio_duration_ms: float
    rtf: float  # Real-Time Factor = latency / audio_duration
    reference: str
    hypothesis: str
    language: str = "he"


@dataclass
class AggregateMetrics:
    """Aggregated metrics across multiple samples for one backend."""

    backend: str
    num_samples: int
    mean_wer: float
    mean_cer: float
    median_wer: float
    median_cer: float
    mean_latency_ms: float
    mean_rtf: float
    min_wer: float
    max_wer: float
    min_cer: float
    max_cer: float
    per_sample: list[MetricResult] = field(default_factory=list)


def compute_wer(reference: str, hypothesis: str) -> float:
    """
    Compute Word Error Rate using jiwer.

    WER = (S + D + I) / N where:
      S = substitutions, D = deletions, I = insertions, N = words in reference.

    Returns 0.0 for empty reference and empty hypothesis (both empty = perfect).
    Returns 1.0 for empty reference with non-empty hypothesis.
    """
    ref = reference.strip()
    hyp = hypothesis.strip()

    if not ref and not hyp:
        return 0.0
    if not ref:
        return 1.0
    if not hyp:
        return 1.0

    return jiwer.wer(ref, hyp)


def compute_cer(reference: str, hypothesis: str) -> float:
    """
    Compute Character Error Rate using jiwer.

    CER is WER at the character level — important for non-Latin scripts
    like Hebrew where word segmentation differs from English.

    Returns 0.0 for empty reference and empty hypothesis.
    Returns 1.0 for empty reference with non-empty hypothesis.
    """
    ref = reference.strip()
    hyp = hypothesis.strip()

    if not ref and not hyp:
        return 0.0
    if not ref:
        return 1.0
    if not hyp:
        return 1.0

    return jiwer.cer(ref, hyp)


def compute_metrics(result: TranscriptionResult) -> MetricResult:
    """Compute all metrics for a single transcription result."""
    wer_val = compute_wer(result.reference, result.hypothesis)
    cer_val = compute_cer(result.reference, result.hypothesis)

    rtf = 0.0
    if result.audio_duration_ms > 0:
        rtf = result.latency_ms / result.audio_duration_ms

    return MetricResult(
        sample_id=result.sample_id,
        backend=result.backend,
        wer=wer_val,
        cer=cer_val,
        latency_ms=result.latency_ms,
        audio_duration_ms=result.audio_duration_ms,
        rtf=rtf,
        reference=result.reference,
        hypothesis=result.hypothesis,
        language=result.language,
    )


def aggregate_metrics(results: list[MetricResult], backend: str) -> AggregateMetrics:
    """Aggregate metrics across multiple samples for one backend."""
    if not results:
        return AggregateMetrics(
            backend=backend,
            num_samples=0,
            mean_wer=0.0,
            mean_cer=0.0,
            median_wer=0.0,
            median_cer=0.0,
            mean_latency_ms=0.0,
            mean_rtf=0.0,
            min_wer=0.0,
            max_wer=0.0,
            min_cer=0.0,
            max_cer=0.0,
            per_sample=[],
        )

    wers = [r.wer for r in results]
    cers = [r.cer for r in results]
    latencies = [r.latency_ms for r in results]
    rtfs = [r.rtf for r in results]

    sorted_wers = sorted(wers)
    sorted_cers = sorted(cers)
    n = len(results)
    mid = n // 2

    median_wer = sorted_wers[mid] if n % 2 == 1 else (sorted_wers[mid - 1] + sorted_wers[mid]) / 2
    median_cer = sorted_cers[mid] if n % 2 == 1 else (sorted_cers[mid - 1] + sorted_cers[mid]) / 2

    return AggregateMetrics(
        backend=backend,
        num_samples=n,
        mean_wer=sum(wers) / n,
        mean_cer=sum(cers) / n,
        median_wer=median_wer,
        median_cer=median_cer,
        mean_latency_ms=sum(latencies) / n,
        mean_rtf=sum(rtfs) / n,
        min_wer=min(wers),
        max_wer=max(wers),
        min_cer=min(cers),
        max_cer=max(cers),
        per_sample=results,
    )


class LatencyTimer:
    """Context manager for measuring transcription latency."""

    def __init__(self):
        self.start_time: float = 0
        self.end_time: float = 0

    def __enter__(self):
        self.start_time = time.perf_counter()
        return self

    def __exit__(self, *_):
        self.end_time = time.perf_counter()

    @property
    def elapsed_ms(self) -> float:
        return (self.end_time - self.start_time) * 1000
