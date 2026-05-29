from __future__ import annotations

from dataclasses import dataclass
from statistics import mean
from typing import Iterable


@dataclass(frozen=True)
class BargeInTrial:
    onset_to_stop_ms: float | None
    false_interrupt: bool


@dataclass(frozen=True)
class BargeInSummary:
    trial_count: int
    confirmed_interrupts: int
    false_interrupts: int
    false_interrupt_rate: float
    average_onset_to_stop_ms: float | None
    p95_onset_to_stop_ms: float | None
    meets_latency_target: bool


def summarize_barge_in_trials(
    trials: Iterable[BargeInTrial],
    latency_target_ms: float = 250,
) -> BargeInSummary:
    collected = list(trials)
    confirmed_latencies = [
        trial.onset_to_stop_ms
        for trial in collected
        if trial.onset_to_stop_ms is not None and not trial.false_interrupt
    ]
    false_interrupts = sum(1 for trial in collected if trial.false_interrupt)
    interrupt_count = false_interrupts + len(confirmed_latencies)
    p95 = percentile(confirmed_latencies, 95) if confirmed_latencies else None

    return BargeInSummary(
        trial_count=len(collected),
        confirmed_interrupts=len(confirmed_latencies),
        false_interrupts=false_interrupts,
        false_interrupt_rate=(
            false_interrupts / interrupt_count if interrupt_count else 0
        ),
        average_onset_to_stop_ms=(
            mean(confirmed_latencies) if confirmed_latencies else None
        ),
        p95_onset_to_stop_ms=p95,
        meets_latency_target=(
            p95 is not None and p95 <= latency_target_ms
        ),
    )


def percentile(values: list[float], percentile_value: float) -> float:
    if not values:
        raise ValueError("percentile requires at least one value")
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    rank = (len(ordered) - 1) * (percentile_value / 100)
    lower = int(rank)
    upper = min(lower + 1, len(ordered) - 1)
    fraction = rank - lower
    return ordered[lower] + (ordered[upper] - ordered[lower]) * fraction
