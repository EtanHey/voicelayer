"""Tests for dataset loading and generation."""

import json
import os
import tempfile

import pytest
from datasets import (
    HEBREW_SAMPLES,
    ENGLISH_REFERENCE_SAMPLES,
    Sample,
    get_carmit_voice,
    generate_synthetic_audio,
    get_audio_duration_ms,
    load_dataset,
    load_real_recordings,
    save_dataset_manifest,
)


class TestHebrewSamples:
    def test_hebrew_samples_not_empty(self):
        assert len(HEBREW_SAMPLES) >= 10

    def test_all_hebrew_samples_have_required_fields(self):
        for sample in HEBREW_SAMPLES:
            assert "id" in sample
            assert "text" in sample
            assert "source" in sample
            assert sample["id"].startswith("he-")

    def test_hebrew_sample_ids_are_unique(self):
        ids = [s["id"] for s in HEBREW_SAMPLES]
        assert len(ids) == len(set(ids))

    def test_english_samples_exist(self):
        assert len(ENGLISH_REFERENCE_SAMPLES) >= 2

    def test_english_samples_have_language_field(self):
        for sample in ENGLISH_REFERENCE_SAMPLES:
            assert sample.get("language") == "en"


class TestCarmitVoice:
    def test_carmit_detection(self):
        result = get_carmit_voice()
        if result is not None:
            assert result == "Carmit"


class TestSyntheticAudioGeneration:
    def test_generate_hebrew_audio(self, temp_dir):
        carmit = get_carmit_voice()
        if not carmit:
            pytest.skip("Carmit voice not available")

        wav_path = os.path.join(temp_dir, "test-he.wav")
        ok = generate_synthetic_audio("שלום עולם", wav_path, voice="Carmit")
        assert ok
        assert os.path.exists(wav_path)
        assert os.path.getsize(wav_path) > 44  # bigger than just WAV header

    def test_generate_english_audio(self, temp_dir):
        wav_path = os.path.join(temp_dir, "test-en.wav")
        ok = generate_synthetic_audio("hello world", wav_path, voice="Samantha")
        assert ok
        assert os.path.exists(wav_path)


class TestAudioDuration:
    def test_duration_from_file_size(self, sample_wav):
        duration = get_audio_duration_ms(sample_wav)
        assert 900 < duration < 1100  # ~1000ms for 1s of audio

    def test_duration_nonexistent_file(self):
        duration = get_audio_duration_ms("/nonexistent/file.wav")
        assert duration == 0.0


class TestLoadDataset:
    def test_load_dataset_generates_audio(self, temp_dir):
        carmit = get_carmit_voice()
        if not carmit:
            pytest.skip("Carmit voice not available")

        samples = load_dataset(temp_dir, include_english=True)
        assert len(samples) > 0

        he_samples = [s for s in samples if s.language == "he"]
        en_samples = [s for s in samples if s.language == "en"]
        assert len(he_samples) > 0
        assert len(en_samples) > 0

        for s in samples:
            assert s.audio_path is not None
            assert os.path.exists(s.audio_path)

    def test_load_dataset_hebrew_only(self, temp_dir):
        carmit = get_carmit_voice()
        if not carmit:
            pytest.skip("Carmit voice not available")

        samples = load_dataset(temp_dir, include_english=False)
        en = [s for s in samples if s.language == "en"]
        assert len(en) == 0


class TestLoadRealRecordings:
    def test_empty_directory(self, temp_dir):
        samples = load_real_recordings(temp_dir)
        assert samples == []

    def test_nonexistent_directory(self):
        samples = load_real_recordings("/nonexistent/path")
        assert samples == []

    def test_wav_with_txt_pair(self, temp_dir):
        from conftest import _write_silent_wav

        wav_path = os.path.join(temp_dir, "sample.wav")
        txt_path = os.path.join(temp_dir, "sample.txt")
        _write_silent_wav(wav_path)

        with open(txt_path, "w", encoding="utf-8") as f:
            f.write("שלום עולם")

        samples = load_real_recordings(temp_dir)
        assert len(samples) == 1
        assert samples[0].reference_text == "שלום עולם"
        assert samples[0].source == "real"


class TestSaveDatasetManifest:
    def test_save_and_read_manifest(self, temp_dir):
        samples = [
            Sample(id="test-1", reference_text="שלום", language="he", source="synthetic"),
            Sample(id="test-2", reference_text="hello", language="en", source="synthetic"),
        ]
        manifest_path = os.path.join(temp_dir, "manifest.json")
        save_dataset_manifest(samples, manifest_path)

        with open(manifest_path, encoding="utf-8") as f:
            data = json.load(f)

        assert data["version"] == "1.0.0"
        assert "bias_warning" in data
        assert len(data["samples"]) == 2
        assert data["samples"][0]["reference_text"] == "שלום"
