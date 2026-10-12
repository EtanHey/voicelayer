import base64
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from test_tts_daemon_security import (  # noqa: E402
    FakeModel,
    install_fake_mlx_audio,
    synthesize_headers,
    synthesize_payload,
)
from tts_daemon import create_app  # noqa: E402


def test_synthesize_uses_mlx_audio_generate_audio_file_api(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
):
    fake_model = FakeModel()
    calls: list[dict[str, object]] = []

    def fake_generate_audio(**kwargs):
        calls.append(kwargs)
        output_dir = Path(str(kwargs["output_path"]))
        file_prefix = str(kwargs["file_prefix"])
        audio_format = str(kwargs["audio_format"])
        (output_dir / f"{file_prefix}.{audio_format}").write_bytes(b"fake-mp3")

    install_fake_mlx_audio(
        monkeypatch,
        fake_model,
        generate_audio=fake_generate_audio,
    )

    secret_file = tmp_path / "daemon.secret"
    secret_file.write_text("test-secret\n", encoding="utf-8")
    secret_file.chmod(0o600)

    voices_root = tmp_path / "voices"
    sample = voices_root / "speaker" / "samples" / "clip.wav"
    sample.parent.mkdir(parents=True)
    sample.write_bytes(b"RIFF" + b"\x00" * 128)

    app = create_app(
        model_path="fake-model",
        auth_token_file=str(secret_file),
        voices_root=str(voices_root),
    )

    with TestClient(app) as client:
        response = client.post(
            "/synthesize",
            headers=synthesize_headers("test-secret"),
            json=synthesize_payload(str(sample)),
        )

    assert response.status_code == 200
    assert base64.b64decode(response.json()["audio_b64"]) == b"fake-mp3"
    assert calls == [
        {
            "text": "hello world",
            "model": fake_model,
            "ref_audio": str(sample.resolve()),
            "ref_text": "hello world",
            "output_path": calls[0]["output_path"],
            "file_prefix": "synthesis",
            "audio_format": "mp3",
            "join_audio": True,
            "verbose": False,
        }
    ]
    assert Path(str(calls[0]["output_path"])).name.startswith("voicelayer-tts-")


def test_synthesize_rejects_profile_model_mismatch(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
):
    fake_model = FakeModel()
    calls: list[dict[str, object]] = []

    def fake_generate_audio(**kwargs):
        calls.append(kwargs)
        output_dir = Path(str(kwargs["output_path"]))
        file_prefix = str(kwargs["file_prefix"])
        audio_format = str(kwargs["audio_format"])
        (output_dir / f"{file_prefix}.{audio_format}").write_bytes(b"fake-mp3")

    install_fake_mlx_audio(
        monkeypatch,
        fake_model,
        generate_audio=fake_generate_audio,
    )

    secret_file = tmp_path / "daemon.secret"
    secret_file.write_text("test-secret\n", encoding="utf-8")
    secret_file.chmod(0o600)

    voices_root = tmp_path / "voices"
    sample = voices_root / "speaker" / "samples" / "clip.wav"
    sample.parent.mkdir(parents=True)
    sample.write_bytes(b"RIFF" + b"\x00" * 128)

    app = create_app(
        model_path=str(tmp_path / "models" / "qwen3-tts-4bit"),
        auth_token_file=str(secret_file),
        voices_root=str(voices_root),
    )

    payload = synthesize_payload(str(sample))
    payload["model"] = str(tmp_path / "models" / "other-qwen3")

    with TestClient(app) as client:
        response = client.post(
            "/synthesize",
            headers=synthesize_headers("test-secret"),
            json=payload,
        )

    assert response.status_code == 409
    assert "model mismatch" in response.text
    assert calls == []


@pytest.mark.parametrize("model_type", ["custom_voice", "voice_design", "base"])
def test_clone_checks_loaded_model_type_not_directory_name(
    monkeypatch, tmp_path, model_type
):
    fake_model = FakeModel()
    fake_model.config = SimpleNamespace(tts_model_type=model_type)
    calls = []

    def generate_audio(**kwargs):
        calls.append(kwargs)
        (Path(kwargs["output_path"]) / "synthesis.mp3").write_bytes(b"fake-mp3")

    install_fake_mlx_audio(monkeypatch, fake_model, generate_audio)
    # A base-looking name must not disguise CustomVoice, and vice versa.
    model_name = "qwen3-tts-4bit" if model_type == "base" else "qwen3-tts-base-4bit"
    model_path = str(tmp_path / "models" / model_name)
    sample = tmp_path / "voices" / "speaker" / "clip.wav"
    sample.parent.mkdir(parents=True)
    sample.write_bytes(b"RIFF" + b"\x00" * 128)
    secret_file = tmp_path / "daemon.secret"
    app = create_app(
        model_path=model_path,
        auth_token_file=str(secret_file),
        voices_root=str(tmp_path / "voices"),
    )
    payload = synthesize_payload(str(sample))
    payload["model"] = model_path
    with TestClient(app) as client:
        response = client.post(
            "/synthesize",
            json=payload,
            headers=synthesize_headers(secret_file.read_text().strip()),
        )
    if model_type == "base":
        assert response.status_code == 200
        assert len(calls) == 1
    else:
        assert response.status_code == 409
        assert response.json()["code"] == "clone_model_incompatible"
        assert model_type in response.json()["detail"]
        assert model_path in response.json()["detail"]
        assert "voicelayer daemon --model" in response.json()["detail"]
        assert "qwen3-tts-base-4bit" in response.json()["detail"]
        assert calls == []


def test_clone_profile_pins_base_model(monkeypatch, tmp_path):
    import importlib.util

    spec = importlib.util.spec_from_file_location("clone_cli", ROOT / "src/cli/clone.py")
    clone = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(clone)
    monkeypatch.setattr(clone, "VOICES_DIR", tmp_path)
    (tmp_path / "fixture").mkdir()
    clone.write_profile("fixture", [{"path": tmp_path / "fixture/clip.wav"}], ["hello"])
    profile = (tmp_path / "fixture/profile.yaml").read_text()
    assert "model_path: ~/.voicelayer/models/qwen3-tts-base-4bit" in profile
