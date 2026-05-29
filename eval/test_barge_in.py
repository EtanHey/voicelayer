import pytest

from barge_in import BargeInTrial, summarize_barge_in_trials


def test_barge_in_summary_tracks_latency_and_false_interrupt_rate():
    summary = summarize_barge_in_trials(
        [
            BargeInTrial(onset_to_stop_ms=44, false_interrupt=False),
            BargeInTrial(onset_to_stop_ms=80, false_interrupt=False),
            BargeInTrial(onset_to_stop_ms=None, false_interrupt=True),
        ]
    )

    assert summary.trial_count == 3
    assert summary.confirmed_interrupts == 2
    assert summary.false_interrupts == 1
    assert summary.false_interrupt_rate == 1 / 3
    assert summary.average_onset_to_stop_ms == 62
    assert summary.p95_onset_to_stop_ms == pytest.approx(78.2)
    assert summary.meets_latency_target is True


def test_barge_in_summary_fails_latency_target_when_p95_exceeds_250ms():
    summary = summarize_barge_in_trials(
        [
            BargeInTrial(onset_to_stop_ms=40, false_interrupt=False),
            BargeInTrial(onset_to_stop_ms=300, false_interrupt=False),
        ]
    )

    assert summary.p95_onset_to_stop_ms == 287
    assert summary.meets_latency_target is False
