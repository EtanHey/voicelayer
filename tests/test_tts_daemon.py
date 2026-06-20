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
