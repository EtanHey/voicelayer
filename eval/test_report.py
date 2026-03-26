"""Tests for report generation."""

import json

import pytest
from metrics import AggregateMetrics, MetricResult
from report import (
    BIAS_WARNING,
    format_comparison_table,
    format_per_sample_table,
    generate_baseline_report,
    generate_json_results,
)


def _make_metric_result(sample_id="s1", wer=0.2, cer=0.1, lang="he"):
    return MetricResult(
        sample_id=sample_id,
        backend="test-backend",
        wer=wer,
        cer=cer,
        latency_ms=150.0,
        audio_duration_ms=2000.0,
        rtf=0.075,
        reference="שלום עולם",
        hypothesis="שלום עלם",
        language=lang,
    )


def _make_aggregate(backend="test-backend", num_samples=5, mean_wer=0.2, per_sample=None):
    return AggregateMetrics(
        backend=backend,
        num_samples=num_samples,
        mean_wer=mean_wer,
        mean_cer=0.1,
        median_wer=0.18,
        median_cer=0.09,
        mean_latency_ms=200.0,
        mean_rtf=0.1,
        min_wer=0.05,
        max_wer=0.4,
        min_cer=0.02,
        max_cer=0.2,
        per_sample=per_sample or [],
    )


class TestFormatComparisonTable:
    def test_empty_aggregates(self):
        result = format_comparison_table([])
        assert "No results" in result

    def test_single_backend(self):
        agg = _make_aggregate()
        table = format_comparison_table([agg])
        assert "test-backend" in table
        assert "20.0%" in table
        assert "200ms" in table

    def test_multiple_backends(self):
        agg1 = _make_aggregate("whisper-cpp", mean_wer=0.15)
        agg2 = _make_aggregate("voicelayer", mean_wer=0.25)
        table = format_comparison_table([agg1, agg2])
        assert "whisper-cpp" in table
        assert "voicelayer" in table

    def test_table_has_header_row(self):
        table = format_comparison_table([_make_aggregate()])
        lines = table.strip().split("\n")
        assert len(lines) >= 3  # header + separator + data
        assert "Backend" in lines[0]
        assert "---" in lines[1]


class TestFormatPerSampleTable:
    def test_empty_results(self):
        result = format_per_sample_table([])
        assert "No per-sample" in result

    def test_per_sample_shows_wer_and_cer(self):
        mr = _make_metric_result()
        table = format_per_sample_table([mr])
        assert "s1" in table
        assert "20.0%" in table


class TestGenerateBaselineReport:
    def test_report_contains_bias_warning(self):
        agg = _make_aggregate()
        report = generate_baseline_report(
            [agg],
            {"total": 10, "hebrew": 8, "english": 2, "sources": ["synthetic"]},
        )
        assert "Synthetic TTS Bias" in report
        assert "overestimates" in report

    def test_report_contains_methodology(self):
        report = generate_baseline_report(
            [_make_aggregate()],
            {"total": 5, "hebrew": 5, "english": 0, "sources": ["synthetic"]},
        )
        assert "Methodology" in report
        assert "jiwer" in report
        assert "PolyWER" in report
        assert "PIER" in report

    def test_report_per_sample_breakdown(self):
        he_sample = _make_metric_result("he-01", lang="he")
        en_sample = _make_metric_result("en-01", lang="en")
        agg = _make_aggregate(per_sample=[he_sample, en_sample])
        report = generate_baseline_report(
            [agg],
            {"total": 2, "hebrew": 1, "english": 1, "sources": ["synthetic"]},
        )
        assert "Hebrew Samples" in report
        assert "English Samples" in report

    def test_report_includes_model_info(self):
        report = generate_baseline_report(
            [_make_aggregate()],
            {"total": 5, "hebrew": 5, "english": 0, "sources": ["synthetic"]},
            model_info="ggml-large-v3-turbo.bin",
        )
        assert "ggml-large-v3-turbo.bin" in report


class TestGenerateJsonResults:
    def test_json_is_valid(self):
        agg = _make_aggregate(per_sample=[_make_metric_result()])
        result = generate_json_results(
            [agg], {"total": 1, "hebrew": 1, "english": 0, "sources": ["synthetic"]}
        )
        data = json.loads(result)
        assert data["version"] == "1.0.0"
        assert "bias_warning" in data
        assert len(data["backends"]) == 1

    def test_json_hebrew_text_preserved(self):
        mr = _make_metric_result()
        agg = _make_aggregate(per_sample=[mr])
        result = generate_json_results(
            [agg], {"total": 1, "hebrew": 1, "english": 0, "sources": ["synthetic"]}
        )
        data = json.loads(result)
        sample = data["backends"][0]["per_sample"][0]
        assert "שלום" in sample["reference"]

    def test_json_metrics_rounded(self):
        mr = _make_metric_result(wer=0.123456789)
        agg = _make_aggregate(per_sample=[mr])
        result = generate_json_results(
            [agg], {"total": 1, "hebrew": 1, "english": 0, "sources": ["synthetic"]}
        )
        data = json.loads(result)
        sample_wer = data["backends"][0]["per_sample"][0]["wer"]
        assert sample_wer == 0.1235  # rounded to 4 decimal places
