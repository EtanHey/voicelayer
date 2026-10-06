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
    model_pin_matches,
    validate_reference_wav_path,
)


class FakeModel:
    pass


def install_fake_mlx_audio(
    monkeypatch: pytest.MonkeyPatch,
    fake_model: FakeModel,
    generate_audio=None,
) -> None:
    def default_generate_audio(**kwargs):
        output_dir = Path(str(kwargs["output_path"]))
        file_prefix = str(kwargs["file_prefix"])
        audio_format = str(kwargs["audio_format"])
        (output_dir / f"{file_prefix}.{audio_format}").write_bytes(b"fake-mp3")

    fake_mlx_audio = SimpleNamespace()
    fake_tts = SimpleNamespace()
    fake_utils = SimpleNamespace(load=lambda _: fake_model)
    fake_generate = SimpleNamespace(generate_audio=generate_audio or default_generate_audio)
    monkeypatch.setitem(sys.modules, "mlx_audio", fake_mlx_audio)
    monkeypatch.setitem(sys.modules, "mlx_audio.tts", fake_tts)
    monkeypatch.setitem(sys.modules, "mlx_audio.tts.utils", fake_utils)
    monkeypatch.setitem(sys.modules, "mlx_audio.tts.generate", fake_generate)


@pytest.fixture
def daemon_client(monkeypatch: pytest.MonkeyPatch, tmp_path: Path):
    fake_model = FakeModel()
    generation_calls = []
    model_load_paths = []

    def generate_audio(**kwargs):
        generation_calls.append(kwargs)
        output = Path(kwargs["output_path"]) / f"{kwargs['file_prefix']}.mp3"
        output.write_bytes(b"fake-mp3")

    def load_model(path):
        model_load_paths.append(path)
        return fake_model

    install_fake_mlx_audio(monkeypatch, fake_model, generate_audio)
    monkeypatch.setattr(sys.modules["mlx_audio.tts.utils"], "load", load_model)

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
            "generation_calls": generation_calls,
            "model_load_paths": model_load_paths,
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


@pytest.mark.parametrize("regular_file", [False, True])
def test_reference_path_equal_to_root_preserves_file_validation(tmp_path, regular_file):
    root = tmp_path / "root.wav"
    if regular_file:
        root.write_bytes(b"RIFF" + b"\x00" * 128)
        assert validate_reference_wav_path(str(root), root) == root.resolve()
    else:
        root.mkdir()
        with pytest.raises(ValueError, match="regular file"):
            validate_reference_wav_path(str(root), root)


def test_reference_path_with_filesystem_root(tmp_path):
    sample = tmp_path / "clip.wav"
    sample.write_bytes(b"RIFF" + b"\x00" * 128)
    assert validate_reference_wav_path(str(sample), Path("/")) == sample.resolve()


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


@pytest.mark.parametrize("path_kind", ["traversal", "absolute", "symlink", "nul", "prefix"])
def test_synthesize_rejects_unsafe_reference_paths(daemon_client, tmp_path, path_kind):
    sample = daemon_client["sample"]
    voices_root = sample.parents[2]
    outside = tmp_path / "outside.wav"
    outside.write_bytes(b"RIFF" + b"\x00" * 128)
    linked = sample.parent / "linked.wav"
    linked.symlink_to(outside)
    prefix = tmp_path / "voices-other" / "clip.wav"
    prefix.parent.mkdir()
    prefix.write_bytes(outside.read_bytes())
    paths = {
        "traversal": str(voices_root / ".." / "outside.wav"),
        "absolute": str(outside),
        "symlink": str(linked),
        "nul": str(sample) + "\x00.wav",
        "prefix": str(prefix),
    }

    response = daemon_client["client"].post(
        "/synthesize",
        headers=synthesize_headers(daemon_client["secret"]),
        json=synthesize_payload(paths[path_kind]),
    )

    assert response.status_code == (400 if path_kind == "nul" else 403)
    assert daemon_client["generation_calls"] == []
    assert daemon_client["model_load_paths"] == ["fake-model"]


@pytest.mark.parametrize("path_kind", ["absolute", "tilde", "symlink", "root-symlink"])
def test_reference_path_preserves_profile_layout(monkeypatch, tmp_path, path_kind):
    monkeypatch.setenv("HOME", str(tmp_path))
    voices_root = tmp_path / ".voicelayer" / "voices"
    profile = voices_root / "fixture-speaker_2"
    sample = profile / "samples" / "clip 01.wav"
    sample.parent.mkdir(parents=True)
    (profile / "profile.yaml").write_text("name: fixture-speaker_2\n")
    sample.write_bytes(b"RIFF" + b"\x00" * 128)
    alias = sample.parent / "alias.wav"
    alias.symlink_to(sample)
    root_alias = tmp_path / "voices-alias"
    root_alias.symlink_to(voices_root, target_is_directory=True)
    paths = {
        "absolute": str(sample),
        "tilde": "~/.voicelayer/voices/fixture-speaker_2/samples/clip 01.wav",
        "symlink": str(alias),
        "root-symlink": str(root_alias / sample.relative_to(voices_root)),
    }

    assert validate_reference_wav_path(paths[path_kind], voices_root) == sample.resolve()


@pytest.mark.parametrize("model_pin", ["../other-model", "/outside/other-model", "fake-model\x00", "symlink"])
def test_synthesize_rejects_unsafe_model_pins(daemon_client, tmp_path, model_pin):
    if model_pin == "symlink":
        outside = tmp_path / "outside-model"
        outside.mkdir()
        alias = tmp_path / "model-alias"
        alias.symlink_to(outside, target_is_directory=True)
        model_pin = str(alias)
    payload = synthesize_payload(str(daemon_client["sample"]))
    payload["model"] = model_pin

    response = daemon_client["client"].post(
        "/synthesize",
        headers=synthesize_headers(daemon_client["secret"]),
        json=payload,
    )

    assert response.status_code == 409
    assert daemon_client["generation_calls"] == []
    assert daemon_client["model_load_paths"] == ["fake-model"]


@pytest.mark.parametrize("pin_kind", ["unset", "blank", "name", "path", "tilde", "normalized"])
def test_model_pin_preserves_loaded_model_identities(monkeypatch, tmp_path, pin_kind):
    monkeypatch.setenv("HOME", str(tmp_path))
    model = tmp_path / "models" / "fixture-model"
    model.mkdir(parents=True)
    pins = {
        "unset": None,
        "blank": "  ",
        "name": "fixture-model",
        "path": str(model),
        "tilde": "~/models/fixture-model",
        "normalized": str(model.parent / "unused" / ".." / model.name),
    }

    assert model_pin_matches(pins[pin_kind], str(model))


@pytest.mark.parametrize("model_pin", ["fake-model", "canonical"])
def test_synthesize_model_pin_only_selects_loaded_model(daemon_client, tmp_path, model_pin):
    loaded_path = (ROOT / "fake-model").resolve()
    pins = {"fake-model": "fake-model", "canonical": str(loaded_path)}
    payload = synthesize_payload(str(daemon_client["sample"]))
    payload["model"] = pins[model_pin]

    response = daemon_client["client"].post(
        "/synthesize",
        headers=synthesize_headers(daemon_client["secret"]),
        json=payload,
    )

    assert response.status_code == 200
    assert daemon_client["model_load_paths"] == ["fake-model"]
    assert len(daemon_client["generation_calls"]) == 1
    assert daemon_client["generation_calls"][0]["model"] is daemon_client["model"]


def test_model_pin_never_resolves_requested_path(monkeypatch, tmp_path):
    loaded = tmp_path / "models" / "fixture-model"
    requested = str(loaded.parent / "unused" / ".." / loaded.name)
    original_resolve = Path.resolve
    resolved_paths = []

    def configured_path_only(path, *args, **kwargs):
        resolved_paths.append(str(path))
        assert str(path) == str(loaded), "request pin reached filesystem resolution"
        return original_resolve(path, *args, **kwargs)

    monkeypatch.setattr(Path, "resolve", configured_path_only)

    assert model_pin_matches(requested, str(loaded))
    assert resolved_paths == [str(loaded)]


def test_model_pin_rejects_requested_symlink_alias(tmp_path):
    loaded = tmp_path / "models" / "fixture-model"
    loaded.mkdir(parents=True)
    alias = tmp_path / "model-alias"
    alias.symlink_to(loaded, target_is_directory=True)

    assert not model_pin_matches(str(alias), str(loaded))
    assert model_pin_matches(str(loaded), str(alias))
