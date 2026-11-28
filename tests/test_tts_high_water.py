import asyncio
import os
import socket
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from tts_daemon import (  # noqa: E402
    HIGH_WATER_BYTES,
    RESTART_OWNER_ENV,
    RESTART_OWNER_PID_ENV,
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
    assert restart_owner_confirmed({RESTART_OWNER_ENV: "voicebar"}) is False
    assert restart_owner_confirmed({RESTART_OWNER_ENV: "voicebar", RESTART_OWNER_PID_ENV: "1"}) is False
    assert restart_owner_confirmed({
        RESTART_OWNER_ENV: "voicebar", RESTART_OWNER_PID_ENV: str(os.getppid()),
    }) is True


def test_retirement_authority_ends_when_the_launching_parent_exits(tmp_path):
    src = Path(__file__).resolve().parents[1] / "src"
    child_code = """
import os
import sys
import time
from pathlib import Path
from tts_daemon import restart_owner_confirmed

directory = Path(sys.argv[1])
owner = os.getppid()
(directory / "before").write_text(str(restart_owner_confirmed()))
deadline = time.monotonic() + 10
while os.getppid() == owner and time.monotonic() < deadline:
    time.sleep(0.01)
assert os.getppid() != owner, "launching parent still alive"
(directory / "after").write_text(str(restart_owner_confirmed()))
"""
    parent_code = """
import os
import subprocess
import sys

env = {**os.environ, "VOICELAYER_CLONE_RESTART_OWNER": "voicebar",
       "VOICELAYER_CLONE_RESTART_OWNER_PID": str(os.getpid())}
subprocess.Popen([sys.executable, "-B", "-c", sys.argv[1], sys.argv[2]], env=env)
sys.stdin.read()
"""

    def read_check(name):
        path = tmp_path / name
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if path.exists() and (value := path.read_text()):
                return value
            time.sleep(0.01)
        pytest.fail(f"Child did not report {name}")

    with subprocess.Popen(
        [sys.executable, "-B", "-c", parent_code, child_code, str(tmp_path)],
        env={**os.environ, "PYTHONPATH": str(src)},
        stdin=subprocess.PIPE,
    ) as parent:
        try:
            assert read_check("before") == "True"
        finally:
            parent.stdin.close()
            parent.wait(timeout=5)
        assert read_check("after") == "False"


def test_voicebar_launcher_names_itself_as_the_restart_owner():
    launcher = (Path(__file__).resolve().parents[1] / "flow-bar/Sources/VoiceBar/CloneEngineRuntime.swift").read_text()
    assert f'"{RESTART_OWNER_ENV}": "voicebar"' in launcher
    assert f'"{RESTART_OWNER_PID_ENV}": String(getpid())' in launcher


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
    """Cross the limit with two admitted requests and the first body still unsent."""
    import httpx

    first_started = threading.Event()
    release_first = threading.Event()
    second_admitted = threading.Event()
    first_send_held = threading.Event()
    retirement_attempted = threading.Event()
    immediate_exits = []
    send_loop = None
    release_send = None
    calls = 0

    class ObservedExecutor(ThreadPoolExecutor):
        def submit(self, fn, *args, **kwargs):
            if len(args) == 3 and args[0].text == "second":
                def run_after_first_send():
                    assert first_send_held.wait(5)
                    return fn(*args, **kwargs)

                future = super().submit(run_after_first_send)
                second_admitted.set()
                return future
            return super().submit(fn, *args, **kwargs)

    monkeypatch.setattr("tts_daemon.ThreadPoolExecutor", ObservedExecutor)

    async def hold_first_body(scope, receive, send):
        async def gated_send(message):
            nonlocal send_loop, release_send
            if message["type"] == "http.response.body":
                send_loop = asyncio.get_running_loop()
                release_send = asyncio.Event()
                first_send_held.set()
                await asyncio.wait_for(release_send.wait(), timeout=10)
            await send(message)

        first = scope["type"] == "http" and (b"x-test-response", b"first") in scope["headers"]
        await app(scope, receive, gated_send if first else send)

    def generate(**kwargs):
        nonlocal calls
        calls += 1
        if calls == 1:
            first_started.set()
            assert release_first.wait(5)
        output = Path(kwargs["output_path"]) / f"{kwargs['file_prefix']}.{kwargs['audio_format']}"
        output.write_bytes(b"audio-%d" % calls)

    voices, sample, secret = _setup(monkeypatch, tmp_path, generate)

    def immediate_exit(code):
        immediate_exits.append(code)
        retirement_attempted.set()
        raise SystemExit(code)

    monkeypatch.setattr(os, "_exit", immediate_exit)
    holder = []

    def request_retirement():
        holder[0].should_exit = True
        retirement_attempted.set()

    def read_rss():
        return HIGH_WATER_BYTES + 1 if first_send_held.is_set() else 0

    app = create_app("stub", auth_token_file=str(secret), voices_root=str(voices),
                     request_retirement=request_retirement, read_rss=read_rss)
    server, thread, listener = _serve(hold_first_body)
    holder.append(server)
    port = listener.getsockname()[1]
    headers = synthesize_headers(secret.read_text().strip())

    def post(name):
        payload = {**synthesize_payload(str(sample)), "text": name}
        with httpx.Client(timeout=15) as client:
            return client.post(f"http://127.0.0.1:{port}/synthesize",
                               headers={**headers, "x-test-response": name}, json=payload)

    with ThreadPoolExecutor(max_workers=2) as clients:
        try:
            first = clients.submit(post, "first")
            assert first_started.wait(5)
            second = clients.submit(post, "second")
            assert second_admitted.wait(5)
            assert not retirement_attempted.is_set()
            release_first.set()
            assert first_send_held.wait(5)
            assert retirement_attempted.wait(5)
            assert immediate_exits == [], "Immediate exit while the first response body is held"
            assert not first.done()
            assert thread.is_alive()
        finally:
            release_first.set()
            if release_send is not None:
                send_loop.call_soon_threadsafe(release_send.set)
            server.should_exit = True
            thread.join(15)
            listener.close()

    for request in (first, second):
        response = request.result()
        assert response.status_code == 200
        assert response.json()["audio_b64"]
    assert not thread.is_alive()


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
