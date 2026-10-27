import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

import httpx
import pytest


def wait_for(predicate, seconds=3):
    deadline = time.monotonic() + seconds
    while not predicate():
        assert time.monotonic() < deadline, "daemon did not reach expected state"
        time.sleep(0.01)


@pytest.fixture
def daemon(tmp_path):
    child = subprocess.Popen(
        [sys.executable, str(Path(__file__).parent / "fixtures/qwen_cancel_daemon.py"), str(tmp_path)],
        env={**os.environ, "HOME": str(tmp_path)},
    )
    try:
        wait_for(lambda: (tmp_path / "ready.json").exists())
        port = json.loads((tmp_path / "ready.json").read_text())["port"]
        with httpx.Client(base_url=f"http://127.0.0.1:{port}", timeout=3,
                          headers={"Authorization": f"Bearer {(tmp_path / 'secret').read_text().strip()}"}) as client:
            def healthy():
                try:
                    return client.get("/health").status_code == 200
                except httpx.TransportError:
                    return False
            wait_for(healthy)
            yield tmp_path, port, client
    finally:
        child.terminate()
        try:
            child.wait(timeout=3)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()


def payload(root, text):
    return {"text": text, "reference_wav": str(root / "voices/clip.wav"), "reference_text": "fixture"}


def start_request(root, port, text):
    body = json.dumps(payload(root, text)).encode()
    connection = socket.create_connection(("127.0.0.1", port), timeout=3)
    connection.sendall((f"POST /synthesize HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n"
                        f"Authorization: Bearer {(root / 'secret').read_text().strip()}\r\n"
                        f"Content-Type: application/json\r\nContent-Length: {len(body)}\r\n\r\n").encode() + body)
    return connection


@pytest.mark.parametrize("text", ["slow", "segments"])
def test_disconnect_stops_generation_and_next_request_succeeds(daemon, text):
    root, port, client = daemon
    with start_request(root, port, text):
        wait_for(lambda: (root / f"steps-{text}").exists())
    started = time.monotonic()
    response = client.post("/synthesize", json=payload(root, "next"))
    assert time.monotonic() - started < 1
    assert response.status_code == 200
    assert set(response.json()) == {"audio_b64", "duration_ms"}
    assert (root / f"closed-{text}").exists()
    assert (root / "cache-cleared").exists()
    assert len((root / f"steps-{text}").read_text().splitlines()) < 300
    assert all(not Path(p).exists() for p in (root / "output-dirs").read_text().splitlines())


def test_queued_disconnect_does_not_cancel_active_or_next_request(daemon):
    root, port, client = daemon
    with start_request(root, port, "slow") as active:
        wait_for(lambda: (root / "started-slow").exists())
        with start_request(root, port, "queued"):
            assert client.get("/health").status_code == 200
        time.sleep(0.15)
        assert not (root / "closed-slow").exists()
        active.close()
    assert client.post("/synthesize", json=payload(root, "next")).status_code == 200
    assert not (root / "started-queued").exists()
    time.sleep(0.1)
    assert client.post("/synthesize", json=payload(root, "later")).status_code == 200


def test_generation_failure_releases_worker(daemon):
    root, _, client = daemon
    assert client.post("/synthesize", json=payload(root, "error")).status_code == 500
    assert client.post("/synthesize", json=payload(root, "next")).status_code == 200


def test_disconnect_during_model_load_skips_generation_and_releases_worker(daemon):
    root, port, client = daemon
    (root / "block-load").touch()
    with start_request(root, port, "slow"):
        wait_for(lambda: (root / "loading").exists())
    time.sleep(0.15)
    (root / "release-load").touch()
    started = time.monotonic()
    response = client.post("/synthesize", json=payload(root, "next"))
    assert time.monotonic() - started < 1
    assert response.status_code == 200
    assert not (root / "started-slow").exists()
    assert (root / "cache-cleared").exists()
