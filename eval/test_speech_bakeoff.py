"""Tests for the two-stage speech bakeoff harness."""

from speech_bakeoff import (
    candidate_statuses,
    compute_stt_text_metrics,
    expected_term_hit_rate,
    load_dev_phrase_samples,
    repeated_tail_rate,
    summarize_statuses,
)


def test_fixture_contains_english_heavy_and_mixed_hebrew_english_sets():
    samples = load_dev_phrase_samples()

    assert len(samples) >= 6
    assert {sample.language_set for sample in samples} == {
        "english-heavy-dev",
        "mixed-hebrew-english-dev",
    }
    assert any("VoiceLayer" in sample.expected_terms for sample in samples)


def test_expected_term_hit_rate_counts_case_insensitive_terms():
    rate = expected_term_hit_rate(
        "please run Bun Test for voicelayer",
        ["bun test", "VoiceLayer", "pull request"],
    )

    assert rate == 2 / 3


def test_repeated_tail_rate_detects_final_duplicate_phrase():
    assert repeated_tail_rate("hello world hello world") > 0
    assert repeated_tail_rate("hello world this is fine") == 0


def test_stt_text_metrics_include_eval_plan_fields():
    sample = load_dev_phrase_samples()[0]
    metrics = compute_stt_text_metrics(sample, sample.text)

    assert metrics.wer == 0
    assert metrics.cer == 0
    assert metrics.repeated_tail_rate == 0
    assert metrics.expected_term_hit_rate == 1
    assert metrics.metric_status == "measured"


def test_candidate_statuses_encode_two_stage_architecture():
    statuses = candidate_statuses()
    summary = summarize_statuses(statuses)

    assert "stage-1-base-selection" in summary["stages"]
    assert "stage-2-voice-layer" in summary["stages"]

    stage_1_names = {item["name"] for item in summary["stages"]["stage-1-base-selection"]}
    stage_2_names = {item["name"] for item in summary["stages"]["stage-2-voice-layer"]}

    assert "whisper.cpp large-v3-turbo" in stage_1_names
    assert "edge-tts" in stage_1_names
    assert "Kokoro-82M/MLX" in stage_1_names
    assert "Theo F5-TTS MLX" in stage_2_names
    assert "Qwen3-TTS zero-shot/daemon" in stage_2_names
