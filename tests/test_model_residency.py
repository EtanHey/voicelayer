import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from fastapi.testclient import TestClient
from test_tts_daemon_security import FakeModel, install_fake_mlx_audio, synthesize_headers, synthesize_payload
from tts_daemon import create_app, model_idle_seconds


def test_lazy_tts_concurrent_load_idle_reload(monkeypatch, tmp_path):
    loads = []
    started, release = threading.Event(), threading.Event()
    blocked = False

    def generate(**kwargs):
        if blocked:
            started.set()
            assert release.wait(2)
        (Path(kwargs["output_path"]) / "synthesis.mp3").write_bytes(b"stub")

    install_fake_mlx_audio(monkeypatch, FakeModel(), generate)
    monkeypatch.setattr(sys.modules["mlx_audio.tts.utils"], "load", lambda p: loads.append(p) or FakeModel())
    monkeypatch.setenv("VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS", "0.03")
    voices = tmp_path / "voices"
    voices.mkdir()
    sample = voices / "clip.wav"
    sample.write_bytes(b"RIFF")
    secret = tmp_path / "secret"
    app = create_app("stub", auth_token_file=str(secret), voices_root=str(voices))
    headers = synthesize_headers(secret.read_text().strip())
    with TestClient(app) as client, ThreadPoolExecutor(2) as pool:
        def synth():
            return client.post("/synthesize", headers=headers, json=synthesize_payload(str(sample)))
        assert loads == []
        assert client.get("/health", headers=headers).json()["model_loaded"] is False
        assert loads == []
        requests = [pool.submit(synth) for _ in range(2)]
        assert [r.result().status_code for r in requests] == [200, 200]
        assert len(loads) == 1
        blocked = True
        request = pool.submit(synth)
        assert started.wait(2)
        time.sleep(0.07)
        assert len(loads) == 1
        release.set()
        assert request.result().status_code == 200
        deadline = time.monotonic() + 2
        while client.get("/health", headers=headers).json()["model_loaded"]:
            assert time.monotonic() < deadline
            time.sleep(0.01)
        assert synth().status_code == 200
        assert len(loads) == 2


def test_request_waits_for_tts_unload_and_retries_failed_load(monkeypatch, tmp_path):
    unload_started, unload_release = threading.Event(), threading.Event()
    loads = []
    install_fake_mlx_audio(monkeypatch, FakeModel())

    def load(path):
        loads.append(path)
        if len(loads) == 1:
            raise RuntimeError("stub failure")
        return FakeModel()

    def clear_cache():
        unload_started.set()
        assert unload_release.wait(2)

    from types import SimpleNamespace
    monkeypatch.setattr(sys.modules["mlx_audio.tts.utils"], "load", load)
    monkeypatch.setitem(sys.modules, "mlx.core", SimpleNamespace(clear_cache=clear_cache))
    monkeypatch.setenv("VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS", "0.01")
    voices = tmp_path / "voices"
    voices.mkdir()
    sample = voices / "clip.wav"
    sample.write_bytes(b"RIFF")
    secret = tmp_path / "secret"
    app = create_app("stub", auth_token_file=str(secret), voices_root=str(voices))
    headers = synthesize_headers(secret.read_text().strip())
    with TestClient(app) as client, ThreadPoolExecutor(1) as pool:
        def synth():
            return client.post("/synthesize", headers=headers, json=synthesize_payload(str(sample)))
        assert synth().status_code == 503
        assert synth().status_code == 200
        assert unload_started.wait(2)
        request = pool.submit(synth)
        time.sleep(0.03)
        assert not request.done()
        unload_release.set()
        assert request.result().status_code == 200
        assert len(loads) == 3


def test_persisted_idle_setting_matches_typescript_contract(monkeypatch, tmp_path):
    settings = tmp_path / "model-residency.json"
    monkeypatch.setenv("VOICELAYER_MODEL_SETTINGS_PATH", str(settings))
    monkeypatch.delenv("VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS", raising=False)
    assert model_idle_seconds() == 600
    settings.write_text('{"version":1,"idle_unload_seconds":31}')
    assert model_idle_seconds() == 31
    monkeypatch.setenv("VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS", "12")
    assert model_idle_seconds() == 12
    monkeypatch.setenv("VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS", "")
    assert model_idle_seconds() == 600


def test_strict_decimal_idle_environment_matches_typescript(monkeypatch):
    for raw, expected in [("1_000", 600), ("0x10", 600), ("1e3", 600), ("+12", 600), (" 12.5 ", 12.5), ("0", 600), ("Infinity", 600)]:
        monkeypatch.setenv("VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS", raw)
        assert model_idle_seconds() == expected
