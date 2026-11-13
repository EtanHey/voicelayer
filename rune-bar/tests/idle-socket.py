#!/usr/bin/env python3
"""Isolated release CPU receipt: real fake-server events, then 40 quiet seconds."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time

root = Path(__file__).resolve().parents[1]
folder = root / f'.idle-{os.getpid()}'
folder.mkdir()
home = folder / 'home'
home.mkdir()
path = folder / 's'
child = None
try:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
        server.bind(str(path))
        server.listen(1)
        server.settimeout(5)
        child = subprocess.Popen([sys.argv[1], '--headless-live', '--socket', str(path)],
                                 env={**os.environ, 'HOME': str(home)})
        with server.accept()[0] as peer:
            start = time.monotonic()
            for line in (root / 'docs/replays/band.ndjson').read_text().splitlines():
                event = json.loads(line)
                due = event.pop('t')
                time.sleep(max(0, due - (time.monotonic() - start)))
                peer.sendall((json.dumps(event) + '\n').encode())
            time.sleep(1.5)  # feedback exit completes before the quiet interval
            print('silent_interval_seconds=40; mode=headless; socket=open', flush=True)
            time.sleep(40)
            assert child.poll() is None
            cpu = subprocess.check_output(['ps', '-p', str(child.pid), '-o', '%cpu='], text=True).strip()
            print(f'idle_cpu={cpu}%', flush=True)
            child.terminate()
            child.wait(timeout=5)
            assert peer.recv(1) == b'', 'client wrote unexpected bytes'
            assert list(home.iterdir()) == []
            assert set(p.name for p in folder.iterdir()) == {'s', 'home'}
            print('handshake=b""; HOME files=0; temp entries=s,home', flush=True)
            assert cpu == '0.0', cpu
finally:
    if child is not None and child.poll() is None:
        child.kill()
        child.wait()
    if path.exists():
        path.unlink()
    home.rmdir()
    folder.rmdir()
