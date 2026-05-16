"""Tests for text-only corrector evaluation."""

import json
from pathlib import Path

import pytest

from eval_corrector import load_corrector_manifest, run_corrector_evaluation


def _write_manifest(path: Path):
    rows = [
        {
            "id": "row-1",
            "source": "test",
            "source_ref": "local-1",
            "split": "heldout",
            "language": "en",
            "app": "test",
            "audio_ref": None,
            "audio_path": None,
            "asr_text": "brain layer",
            "formatted_text": "brain layer",
            "edited_text": "BrainLayer",
            "input_text": "brain layer",
            "input_source": "asr_text",
            "target_text": "BrainLayer",
            "target_source": "edited_text",
            "should_change": True,
            "protected_terms": ["BrainLayer"],
            "dictionary_terms": ["BrainLayer"],
            "num_words": 2,
            "speech_duration": None,
            "num_dictionary_replacements": 1,
            "num_words_corrected": 1,
            "average_log_prob": None,
            "tags": ["dictionary-heavy"],
            "notes": "unit fixture",
        },
        {
            "id": "row-2",
            "source": "test",
            "source_ref": "local-2",
            "split": "heldout",
            "language": "en",
            "app": "test",
            "audio_ref": None,
            "audio_path": None,
            "asr_text": "already fine",
            "formatted_text": "already fine",
            "edited_text": "already fine",
            "input_text": "already fine",
            "input_source": "formatted_text",
            "target_text": "already fine",
            "target_source": "formatted_text",
            "should_change": False,
            "protected_terms": [],
            "dictionary_terms": [],
            "num_words": 2,
            "speech_duration": None,
            "num_dictionary_replacements": 0,
            "num_words_corrected": 0,
            "average_log_prob": None,
            "tags": ["no-op"],
            "notes": "unit fixture",
        },
    ]
    with path.open("w", encoding="utf-8") as f:
        for row in rows:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")


def test_load_corrector_manifest_requires_contract_fields(tmp_path):
    manifest = tmp_path / "heldout-corrector.jsonl"
    _write_manifest(manifest)

    rows = load_corrector_manifest(manifest)

    assert [row.id for row in rows] == ["row-1", "row-2"]
    assert rows[0].input_text == "brain layer"
    assert rows[0].target_text == "BrainLayer"


def test_load_corrector_manifest_rejects_missing_fields(tmp_path):
    manifest = tmp_path / "bad.jsonl"
    manifest.write_text(json.dumps({"id": "bad", "input_text": "x"}) + "\n")

    with pytest.raises(ValueError, match="missing required fields"):
        load_corrector_manifest(manifest)


def test_run_corrector_evaluation_writes_json_and_markdown_reports(tmp_path):
    manifest = tmp_path / "heldout-corrector.jsonl"
    reports = tmp_path / "reports"
    _write_manifest(manifest)

    result = run_corrector_evaluation(
        manifest_path=manifest,
        output_dir=reports,
        backends=("identity", "rules"),
    )

    assert result["dataset"]["total"] == 2
    assert {b["name"] for b in result["backends"]} == {"identity", "rules"}
    identity = next(b for b in result["backends"] if b["name"] == "identity")
    rules = next(b for b in result["backends"] if b["name"] == "rules")
    assert rules["mean_wer"] < identity["mean_wer"]
    assert rules["mean_latency_ms"] < 10
    assert "dictionary-heavy" in rules["categories"]
    assert rules["categories"]["dictionary-heavy"]["num_samples"] == 1
    assert rules["per_sample"][0]["sample_id"] == "row-1"
    assert rules["per_sample"][0]["input_words"] == 2
    assert result["sanity_row"]["sample_id"] == "row-1"

    assert result["json_path"].name.startswith("corrector-")
    assert result["json_path"].suffix == ".json"
    assert result["markdown_path"].suffix == ".md"
    assert result["json_path"].exists()
    assert result["markdown_path"].exists()
    assert "categories" in rules
    assert rules["categories"]["dictionary-heavy"]["num_samples"] == 1
    markdown = result["markdown_path"].read_text(encoding="utf-8")
    assert "## Per-Category Aggregates" in markdown
    assert "## Per-Row Breakdown" in markdown
    assert "## Sanity Row" in markdown
    assert "row-1" in markdown
    assert result["sanity_row"]["sample_id"] == "row-1"
    assert result["sanity_row"]["rules_output"] == "BrainLayer"
