import socket
import sys
import threading
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from tts_daemon import (  # noqa: E402
    HIGH_WATER_BYTES,
    RESTART_OWNER_ENV,
    create_app,
    restart_owner_confirmed,
    retire_over_high_water,
)
from test_tts_daemon_security import (  # noqa: E402
    FakeModel,
    install_fake_mlx_audio,
    synthesize_headers,
    synthesize_payload,
)


def test_retirement_is_requested_only_above_the_limit():
    requests = []
    assert retire_over_high_water(lambda: HIGH_WATER_BYTES, lambda: requests.append(1)) is False
    assert requests == []
    assert retire_over_high_water(lambda: HIGH_WATER_BYTES + 1, lambda: requests.append(1)) is True
    assert requests == [1]


def test_unknown_rss_keeps_the_daemon():
    requests = []
    assert retire_over_high_water(lambda: None, lambda: requests.append(1)) is False
    assert requests == []


def test_without_a_restart_owner_nothing_retires_even_far_over_the_limit():
    requests = []
    assert retire_over_high_water(lambda: 10 * HIGH_WATER_BYTES, None) is False
    assert requests == []


def test_only_a_daemon_its_restart_owner_launched_may_retire():
    assert restart_owner_confirmed({}) is False
    assert restart_owner_confirmed({RESTART_OWNER_ENV: ""}) is False
    assert restart_owner_confirmed({RESTART_OWNER_ENV: "somebody"}) is False
    assert restart_owner_confirmed({RESTART_OWNER_ENV: "voicebar"}) is True


def test_voicebar_launcher_names_itself_as_the_restart_owner():
    launcher = (Path(__file__).resolve().parents[1] / "flow-bar/Sources/VoiceBar/CloneEngineRuntime.swift").read_text()
    assert f'"{RESTART_OWNER_ENV}": "voicebar"' in launcher


def _serve(app):
    """Run the app on a real uvicorn server in a thread; return (server, thread, port)."""
    import uvicorn

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.bind(("127.0.0.1", 0))
    listener.listen(16)
    server = uvicorn.Server(uvicorn.Config(app, fd=listener.fileno(), log_level="warning"))
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()
    deadline = time.monotonic() + 5
    while not server.started:
        assert time.monotonic() < deadline
        time.sleep(0.01)
    return server, thread, listener


def _setup(monkeypatch, tmp_path, generate):
    install_fake_mlx_audio(monkeypatch, FakeModel(), generate)
    voices = tmp_path / "voices"
    voices.mkdir()
    sample = voices / "clip.wav"
    sample.write_bytes(b"RIFF")
    secret = tmp_path / "secret"
    return voices, sample, secret


def test_retirement_waits_for_the_held_response_and_the_queued_one(monkeypatch, tmp_path):
    """Two requests: the first is held mid-generation, the second queues behind it on the single
    model executor. Releasing the first with memory over the limit must still deliver BOTH audio
    responses before the server stops; the old code called os._exit in the second request's worker
    and lost both."""
    import httpx

    first_started, release_first = threading.Event(), threading.Event()
    calls = []

    def generate(**kwargs):
        calls.append(kwargs["text"] if "text" in kwargs else len(calls))
        if len(calls) == 1:
            first_started.set()
            assert release_first.wait(10)
        (Path(kwargs["output_path"]) / f"{kwargs['file_prefix']}.{kwargs['audio_format']}").write_bytes(b"audio-%d" % len(calls))

    voices, sample, secret = _setup(monkeypatch, tmp_path, generate)
    retired = threading.Event()
    exits = []
    monkeypatch.setattr("os._exit", lambda code: exits.append(code))  # the old behaviour: never reached now

    holder = []

    def request_retirement():
        retired.set()
        holder[0].should_exit = True

    app = create_app("stub", auth_token_file=str(secret), voices_root=str(voices),
                     request_retirement=request_retirement, read_rss=lambda: HIGH_WATER_BYTES + 1)
    server, thread, listener = _serve(app)
    holder.append(server)
    port = listener.getsockname()[1]
    headers = synthesize_headers(secret.read_text().strip())
    results = {}

    def post(name):
        with httpx.Client(timeout=20) as client:
            results[name] = client.post(f"http://127.0.0.1:{port}/synthesize", headers=headers,
                                        json=synthesize_payload(str(sample)))

    first = threading.Thread(target=post, args=("first",))
    first.start()
    assert first_started.wait(5), results
    second = threading.Thread(target=post, args=("second",))
    second.start()
    time.sleep(0.3)  # the second request is now queued behind the held first one
    assert not retired.is_set()
    release_first.set()
    first.join(15)
    second.join(15)
    thread.join(15)
    listener.close()

    assert exits == []
    assert retired.is_set()
    assert results["first"].status_code == 200 and results["second"].status_code == 200
    assert results["first"].json()["audio_b64"] and results["second"].json()["audio_b64"]
    assert not thread.is_alive()  # the server stopped only after both responses were delivered


def test_a_daemon_with_no_restart_owner_keeps_serving_over_the_limit(monkeypatch, tmp_path):
    from fastapi.testclient import TestClient

    def generate(**kwargs):
        (Path(kwargs["output_path"]) / f"{kwargs['file_prefix']}.{kwargs['audio_format']}").write_bytes(b"audio")

    voices, sample, secret = _setup(monkeypatch, tmp_path, generate)
    exits = []
    monkeypatch.setattr("os._exit", lambda code: exits.append(code))
    app = create_app("stub", auth_token_file=str(secret), voices_root=str(voices),
                     request_retirement=None, read_rss=lambda: 10 * HIGH_WATER_BYTES)
    headers = synthesize_headers(secret.read_text().strip())
    with TestClient(app) as client:
        for _ in range(3):
            assert client.post("/synthesize", headers=headers, json=synthesize_payload(str(sample))).status_code == 200
    assert exits == []
