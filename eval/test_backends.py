"""Tests for STT evaluation backend wrappers."""

import os

import pytest
from backends import (
    WhisperCppBackend,
    VoiceLayerBackend,
    WisprFlowBackend,
    get_available_backends,
)


class TestWhisperCppBackend:
    def test_name(self):
        backend = WhisperCppBackend()
        assert backend.name == "whisper-cpp"

    def test_availability_check(self):
        backend = WhisperCppBackend()
        available = backend.is_available()
        assert isinstance(available, bool)

    def test_model_name_before_init(self):
        backend = WhisperCppBackend()
        name = backend.get_model_name()
        assert isinstance(name, str)

    def test_transcribe_raises_without_binary(self):
        backend = WhisperCppBackend()
        backend.binary_path = None
        backend.model_path = None
        with pytest.raises(RuntimeError, match="not found"):
            backend.transcribe("/nonexistent.wav")


class TestVoiceLayerBackend:
    def test_name(self):
        backend = VoiceLayerBackend()
        assert backend.name == "voicelayer"

    def test_availability_checks_stt_file(self):
        project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        backend = VoiceLayerBackend(project_root=project_root)
        assert backend.is_available() is True

    def test_unavailable_with_bad_root(self):
        backend = VoiceLayerBackend(project_root="/nonexistent/path")
        assert backend.is_available() is False


class TestWisprFlowBackend:
    def test_name(self):
        backend = WisprFlowBackend()
        assert backend.name == "wispr-flow"

    def test_availability_without_key(self):
        original = os.environ.pop("QA_VOICE_WISPR_KEY", None)
        try:
            backend = WisprFlowBackend()
            assert backend.is_available() is False
        finally:
            if original is not None:
                os.environ["QA_VOICE_WISPR_KEY"] = original

    def test_transcribe_raises_not_implemented(self):
        backend = WisprFlowBackend()
        with pytest.raises(NotImplementedError):
            backend.transcribe("/test.wav")


class TestGetAvailableBackends:
    def test_returns_list(self):
        backends = get_available_backends()
        assert isinstance(backends, list)

    def test_all_backends_have_name(self):
        backends = get_available_backends()
        for b in backends:
            assert hasattr(b, "name")
            assert isinstance(b.name, str)
