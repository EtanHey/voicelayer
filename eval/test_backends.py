"""Tests for STT evaluation backend wrappers."""

import os

import pytest
from backends import (
    WhisperCppBackend,
    VoiceLayerBackend,
    WisprFlowBackend,
    get_available_backends,
)
from eval_stt import backend_matches_filter


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

    def test_voicelayer_alias_matches_split_backends(self):
        resident = VoiceLayerBackend(
            name="voicelayer-resident",
            aliases=("voicelayer", "resident", "whisper-server"),
        )
        cli = VoiceLayerBackend(
            name="voicelayer-cli",
            aliases=("voicelayer", "cli", "whisper"),
        )

        assert backend_matches_filter(resident, "voicelayer") is True
        assert backend_matches_filter(cli, "voicelayer") is True
        assert backend_matches_filter(resident, "resident") is True
        assert backend_matches_filter(cli, "cli") is True
        assert backend_matches_filter(resident, "whisper-server") is True
        assert backend_matches_filter(cli, "whisper") is True

    def test_resident_backend_sets_backend_env(self, monkeypatch):
        captured = {}

        def fake_run(cmd, capture_output, text, timeout, cwd, env):
            captured["cmd"] = cmd
            captured["env"] = env

            class Result:
                returncode = 0
                stdout = '{"text":"hello","durationMs":42,"backend":"whisper-server"}\n'
                stderr = ""

            return Result()

        monkeypatch.setattr("subprocess.run", fake_run)
        backend = VoiceLayerBackend(
            name="voicelayer-resident",
            stt_backend="whisper-server",
            project_root=os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        )

        text, latency_ms = backend.transcribe("/tmp/sample.wav", language="auto")

        assert text == "hello"
        assert latency_ms == 42
        assert backend.last_backend == "whisper-server"
        assert captured["cmd"][:2] == ["bun", "--eval"]
        assert captured["env"]["QA_VOICE_STT_BACKEND"] == "whisper-server"
        assert captured["env"]["QA_VOICE_WHISPER_LANG"] == "auto"

    def test_resident_backend_surfaces_fallback_backend(self, monkeypatch):
        def fake_run(cmd, capture_output, text, timeout, cwd, env):
            class Result:
                returncode = 0
                stdout = (
                    '{"text":"hello","durationMs":42,'
                    '"backend":"whisper-server->whisper-cpp"}\n'
                )
                stderr = ""

            return Result()

        monkeypatch.setattr("subprocess.run", fake_run)
        backend = VoiceLayerBackend(
            name="voicelayer-resident",
            stt_backend="whisper-server",
            project_root=os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        )

        text, latency_ms = backend.transcribe("/tmp/sample.wav", language="he")

        assert text == "hello"
        assert latency_ms == 42
        assert backend.last_backend == "whisper-server->whisper-cpp"

    def test_backend_omission_falls_back_to_configured_stt_backend(self, monkeypatch):
        def fake_run(cmd, capture_output, text, timeout, cwd, env):
            class Result:
                returncode = 0
                stdout = '{"text":"hello","durationMs":42}\n'
                stderr = ""

            return Result()

        monkeypatch.setattr("subprocess.run", fake_run)
        backend = VoiceLayerBackend(
            name="voicelayer-resident",
            stt_backend="whisper-server",
            project_root=os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        )

        backend.transcribe("/tmp/sample.wav", language="he")

        assert backend.last_backend == "whisper-server"

    def test_cli_backend_sets_backend_env(self, monkeypatch):
        captured = {}

        def fake_run(cmd, capture_output, text, timeout, cwd, env):
            captured["env"] = env

            class Result:
                returncode = 0
                stdout = '{"text":"hello","durationMs":42,"backend":"whisper-cpp"}\n'
                stderr = ""

            return Result()

        monkeypatch.setattr("subprocess.run", fake_run)
        backend = VoiceLayerBackend(
            name="voicelayer-cli",
            stt_backend="whisper",
            project_root=os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        )

        backend.transcribe("/tmp/sample.wav", language="he")

        assert captured["env"]["QA_VOICE_STT_BACKEND"] == "whisper"
        assert captured["env"]["QA_VOICE_WHISPER_LANG"] == "he"

    def test_availability_checks_stt_file(self, monkeypatch):
        def fake_run(cmd, capture_output, text, timeout, cwd, env):
            class Result:
                returncode = 0
                stdout = "AVAILABLE\n"
                stderr = ""

            return Result()

        monkeypatch.setattr("subprocess.run", fake_run)
        project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        backend = VoiceLayerBackend(project_root=project_root)
        assert backend.is_available() is True

    def test_unavailable_with_bad_root(self):
        backend = VoiceLayerBackend(project_root="/nonexistent/path")
        assert backend.is_available() is False

    def test_mode_specific_availability_probe(self, monkeypatch):
        def fake_run(cmd, capture_output, text, timeout, cwd, env):
            class Result:
                returncode = 0
                stdout = "AVAILABLE\n"
                stderr = ""

            return Result()

        monkeypatch.setattr("subprocess.run", fake_run)
        backend = VoiceLayerBackend(
            name="voicelayer-resident",
            stt_backend="whisper-server",
            project_root=os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        )

        assert backend.is_available() is True

    def test_mode_specific_unavailable_probe(self, monkeypatch):
        def fake_run(cmd, capture_output, text, timeout, cwd, env):
            class Result:
                returncode = 0
                stdout = "UNAVAILABLE\n"
                stderr = ""

            return Result()

        monkeypatch.setattr("subprocess.run", fake_run)
        backend = VoiceLayerBackend(
            name="voicelayer-resident",
            stt_backend="whisper-server",
            project_root=os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        )

        assert backend.is_available() is False

    def test_mode_specific_probe_failure_is_unavailable(self, monkeypatch):
        def fake_run(cmd, capture_output, text, timeout, cwd, env):
            class Result:
                returncode = 1
                stdout = ""
                stderr = "backend unavailable"

            return Result()

        monkeypatch.setattr("subprocess.run", fake_run)
        backend = VoiceLayerBackend(
            name="voicelayer-resident",
            stt_backend="whisper-server",
            project_root=os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        )

        assert backend.is_available() is False


class TestWisprFlowBackend:
    def test_name(self):
        backend = WisprFlowBackend()
        assert backend.name == "wispr-flow"

    def test_aliases(self):
        backend = WisprFlowBackend()
        assert backend.aliases == ("wispr", "wispr-flow")
        assert backend_matches_filter(backend, "wispr") is True

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

    def test_includes_side_by_side_voicelayer_backends(self, monkeypatch):
        def fake_run(cmd, capture_output, text, timeout, cwd=None, env=None):
            if cmd[:1] == ["which"]:
                class MissingBinary:
                    returncode = 1
                    stdout = ""
                    stderr = ""

                return MissingBinary()

            class Available:
                returncode = 0
                stdout = "AVAILABLE\n"
                stderr = ""

            return Available()

        monkeypatch.setattr("subprocess.run", fake_run)
        project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        backends = get_available_backends(project_root=project_root)
        names = [b.name for b in backends]

        assert "voicelayer-resident" in names
        assert "voicelayer-cli" in names
        resident = next(b for b in backends if b.name == "voicelayer-resident")
        cli = next(b for b in backends if b.name == "voicelayer-cli")
        assert backend_matches_filter(resident, "whisper-server") is True
        assert backend_matches_filter(cli, "whisper") is True
