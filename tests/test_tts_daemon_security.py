import stat
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from tts_daemon import (  # noqa: E402
    build_allowed_hosts,
    build_allowed_origins,
    create_app,
    enforce_local_request,
    ensure_bearer_token_file,
    validate_reference_wav_path,
)


class FakeAudio:
    def to_bytes(self, format: str = "mp3") -> bytes:
        assert format == "mp3"
        return b"fake-mp3"


class FakeModel:
    def __init__(self) -> None:
        self.calls: list[dict[str, str]] = []

    def generate(
        self,
        *,
        text: str,
        reference_audio: str,
        reference_text: str,
    ) -> FakeAudio:
        self.calls.append(
            {
                "text": text,
                "reference_audio": reference_audio,
                "reference_text": reference_text,
            }
        )
        return FakeAudio()


@pytest.fixture
def daemon_client(monkeypatch: pytest.MonkeyPatch, tmp_path: Path):
    fake_model = FakeModel()
    monkeypatch.setitem(
        sys.modules,
        "mlx_audio",
        SimpleNamespace(load=lambda _: fake_model),
    )

    secret_file = tmp_path / "daemon.secret"
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
        yield {
            "client": client,
            "secret": secret_file.read_text(encoding="utf-8").strip(),
            "sample": sample,
            "model": fake_model,
        }


def synthesize_headers(secret: str | None, **extra_headers: str) -> dict[str, str]:
    headers = {"Host": "127.0.0.1:8880"}
    if secret is not None:
        headers["Authorization"] = f"Bearer {secret}"
    headers.update(extra_headers)
    return headers


def synthesize_payload(reference_wav: str) -> dict[str, str]:
    return {
        "text": "hello world",
        "reference_wav": reference_wav,
        "reference_text": "hello world",
    }


def test_ensure_bearer_token_file_creates_mode_0600_file(tmp_path: Path):
    secret_file = tmp_path / "daemon.secret"

    secret = ensure_bearer_token_file(secret_file)

    assert secret
    assert secret_file.exists()
    assert stat.S_IMODE(secret_file.stat().st_mode) == 0o600


def test_ensure_bearer_token_file_chmods_existing_file_to_0600(tmp_path: Path):
    secret_file = tmp_path / "daemon.secret"
    secret_file.write_text("existing-secret\n", encoding="utf-8")
    secret_file.chmod(0o644)

    secret = ensure_bearer_token_file(secret_file)

    assert secret == "existing-secret"
    assert stat.S_IMODE(secret_file.stat().st_mode) == 0o600


def test_enforce_local_request_rejects_non_local_origin():
    with pytest.raises(PermissionError):
        enforce_local_request(
            {"host": "127.0.0.1:8880", "origin": "https://evil.tld"},
            build_allowed_hosts(8880),
            build_allowed_origins(8880),
        )


def test_validate_reference_wav_path_rejects_symlink_escape(tmp_path: Path):
    voices_root = tmp_path / "voices"
    inside = voices_root / "speaker" / "samples"
    inside.mkdir(parents=True)

    outside = tmp_path / "outside.wav"
    outside.write_bytes(b"RIFF" + b"\x00" * 128)

    escaped = inside / "escaped.wav"
    escaped.symlink_to(outside)

    with pytest.raises(PermissionError):
        validate_reference_wav_path(str(escaped), voices_root)


def test_synthesize_missing_auth_returns_401(daemon_client):
    response = daemon_client["client"].post(
        "/synthesize",
        headers=synthesize_headers(None),
        json=synthesize_payload(str(daemon_client["sample"])),
    )

    assert response.status_code == 401


def test_synthesize_wrong_secret_returns_401(daemon_client):
    response = daemon_client["client"].post(
        "/synthesize",
        headers=synthesize_headers("wrong-secret"),
        json=synthesize_payload(str(daemon_client["sample"])),
    )

    assert response.status_code == 401


def test_synthesize_rejects_non_local_origin(daemon_client):
    response = daemon_client["client"].post(
        "/synthesize",
        headers=synthesize_headers(
            daemon_client["secret"],
            Origin="https://evil.tld",
        ),
        json=synthesize_payload(str(daemon_client["sample"])),
    )

    assert response.status_code == 403


def test_synthesize_rejects_reference_wav_outside_allowlist(daemon_client):
    response = daemon_client["client"].post(
        "/synthesize",
        headers=synthesize_headers(daemon_client["secret"]),
        json=synthesize_payload("/etc/passwd"),
    )

    assert response.status_code == 403


def test_synthesize_accepts_valid_authenticated_request(daemon_client):
    response = daemon_client["client"].post(
        "/synthesize",
        headers=synthesize_headers(daemon_client["secret"]),
        json=synthesize_payload(str(daemon_client["sample"])),
    )

    assert response.status_code == 200
    assert response.json()["audio_b64"]
    assert daemon_client["model"].calls == [
        {
            "text": "hello world",
            "reference_audio": str(daemon_client["sample"].resolve()),
            "reference_text": "hello world",
        }
    ]
