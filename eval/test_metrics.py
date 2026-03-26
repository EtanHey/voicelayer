"""Tests for STT evaluation metrics (WER, CER, latency)."""

import pytest
from metrics import (
    compute_wer,
    compute_cer,
    compute_metrics,
    aggregate_metrics,
    TranscriptionResult,
    MetricResult,
    LatencyTimer,
)


class TestComputeWER:
    def test_identical_strings_return_zero(self):
        assert compute_wer("שלום עולם", "שלום עולם") == 0.0

    def test_completely_different_strings(self):
        wer = compute_wer("שלום", "ביי")
        assert wer == 1.0

    def test_partial_match(self):
        wer = compute_wer("שלום מה שלומך", "שלום מה נשמע")
        assert 0.0 < wer < 1.0

    def test_empty_reference_and_hypothesis_returns_zero(self):
        assert compute_wer("", "") == 0.0

    def test_empty_reference_with_text_returns_one(self):
        assert compute_wer("", "some text") == 1.0

    def test_empty_hypothesis_returns_one(self):
        assert compute_wer("some text", "") == 1.0

    def test_english_baseline(self):
        ref = "the quick brown fox"
        hyp = "the quick brown fox"
        assert compute_wer(ref, hyp) == 0.0

    def test_insertion_error(self):
        wer = compute_wer("שלום עולם", "שלום שלום עולם")
        assert wer > 0.0

    def test_deletion_error(self):
        wer = compute_wer("שלום מה שלומך היום", "שלום שלומך")
        assert wer > 0.0


class TestComputeCER:
    def test_identical_strings_return_zero(self):
        assert compute_cer("שלום", "שלום") == 0.0

    def test_single_char_difference(self):
        cer = compute_cer("שלום", "שלומ")
        assert cer > 0.0

    def test_empty_both_returns_zero(self):
        assert compute_cer("", "") == 0.0

    def test_hebrew_characters(self):
        ref = "בדיקה"
        hyp = "בדיקה"
        assert compute_cer(ref, hyp) == 0.0

    def test_cer_lower_than_wer_for_partial_word_errors(self):
        ref = "שלומך"
        hyp = "שלומכ"
        cer = compute_cer(ref, hyp)
        wer = compute_wer(ref, hyp)
        assert cer <= wer


class TestComputeMetrics:
    def test_perfect_transcription(self):
        result = TranscriptionResult(
            reference="שלום עולם",
            hypothesis="שלום עולם",
            backend="test",
            sample_id="test-01",
            latency_ms=100.0,
            audio_duration_ms=2000.0,
        )
        metrics = compute_metrics(result)
        assert metrics.wer == 0.0
        assert metrics.cer == 0.0
        assert metrics.latency_ms == 100.0
        assert metrics.rtf == pytest.approx(0.05)

    def test_rtf_calculation(self):
        result = TranscriptionResult(
            reference="test",
            hypothesis="test",
            backend="test",
            sample_id="test-02",
            latency_ms=500.0,
            audio_duration_ms=1000.0,
        )
        metrics = compute_metrics(result)
        assert metrics.rtf == pytest.approx(0.5)

    def test_zero_audio_duration_rtf(self):
        result = TranscriptionResult(
            reference="test",
            hypothesis="test",
            backend="test",
            sample_id="test-03",
            latency_ms=100.0,
            audio_duration_ms=0.0,
        )
        metrics = compute_metrics(result)
        assert metrics.rtf == 0.0


class TestAggregateMetrics:
    def test_single_result(self):
        mr = MetricResult(
            sample_id="s1",
            backend="test",
            wer=0.25,
            cer=0.1,
            latency_ms=200.0,
            audio_duration_ms=2000.0,
            rtf=0.1,
            reference="ref",
            hypothesis="hyp",
        )
        agg = aggregate_metrics([mr], "test")
        assert agg.num_samples == 1
        assert agg.mean_wer == 0.25
        assert agg.median_wer == 0.25
        assert agg.min_wer == 0.25
        assert agg.max_wer == 0.25

    def test_multiple_results(self):
        results = [
            MetricResult("s1", "test", 0.1, 0.05, 100, 2000, 0.05, "r", "h"),
            MetricResult("s2", "test", 0.3, 0.15, 200, 2000, 0.1, "r", "h"),
            MetricResult("s3", "test", 0.5, 0.25, 300, 2000, 0.15, "r", "h"),
        ]
        agg = aggregate_metrics(results, "test")
        assert agg.num_samples == 3
        assert agg.mean_wer == pytest.approx(0.3)
        assert agg.median_wer == pytest.approx(0.3)
        assert agg.min_wer == 0.1
        assert agg.max_wer == 0.5

    def test_empty_results(self):
        agg = aggregate_metrics([], "test")
        assert agg.num_samples == 0
        assert agg.mean_wer == 0.0

    def test_even_number_median(self):
        results = [
            MetricResult("s1", "test", 0.1, 0.05, 100, 2000, 0.05, "r", "h"),
            MetricResult("s2", "test", 0.3, 0.15, 200, 2000, 0.1, "r", "h"),
        ]
        agg = aggregate_metrics(results, "test")
        assert agg.median_wer == pytest.approx(0.2)


class TestLatencyTimer:
    def test_timer_measures_elapsed(self):
        import time

        with LatencyTimer() as t:
            time.sleep(0.01)

        assert t.elapsed_ms >= 5  # at least ~10ms but allow some slack
        assert t.elapsed_ms < 1000  # less than 1 second
