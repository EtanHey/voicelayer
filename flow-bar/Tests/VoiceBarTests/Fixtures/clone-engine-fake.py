"""Fake engine only: ephemeral HTTP, no audio, models, microphone or live files."""
import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import sys
import signal

# In this mode the Swift fixture owns the launcher, so it can kill the
# original restart owner before the replacement controller probes /health.
if "--restart-owner" in sys.argv:
    import subprocess
    from time import sleep

    env = {**os.environ, "VOICELAYER_CLONE_RESTART_OWNER": "voicebar",
           "VOICELAYER_CLONE_RESTART_OWNER_PID": str(os.getpid()),
           "PYTHONDONTWRITEBYTECODE": "1"}
    # Foundation's Process.terminate() signals the launcher's process group.
    # Give the fake engine its own session so it survives losing its parent.
    subprocess.Popen(
        [sys.executable, __file__, sys.argv[1], "--orphanable", sys.argv[3]],
        env=env,
        start_new_session=True,
    )
    sleep(30)
    sys.exit(0)

if "--orphanable" in sys.argv:
    import __future__

    # Apple's fixture interpreter can be Python 3.9. Postpone the daemon's
    # newer annotations when loading it to exercise its standalone helpers.
    source = Path(sys.argv[3]) / "tts_daemon.py"
    daemon = {"__name__": "tts_daemon", "__file__": str(source)}
    exec(compile(source.read_bytes(), str(source), "exec",
                 flags=__future__.annotations.compiler_flag), daemon)
    assert daemon["restart_owner_confirmed"]()


class Health(BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"status": "ok", "pid": os.getpid(), "model_loaded": False}).encode()
        self.send_response(200 if self.headers.get("Authorization") == "Bearer fake-engine-token" else 401)
        self.end_headers()
        self.wfile.write(body)
        if "--orphanable" in sys.argv and self.path == "/high-water":
            request_retirement = (lambda: sys.exit(75)) if daemon["restart_owner_confirmed"]() else None
            daemon["retire_over_high_water"](lambda: daemon["HIGH_WATER_BYTES"] + 1, request_retirement)
    def log_message(self, *args):
        pass

if "--ignore-term" in sys.argv:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
server = HTTPServer(("127.0.0.1", 0), Health)
Path(sys.argv[1]).write_text(str(server.server_port))
if "--orphanable" in sys.argv:
    from time import monotonic

    # Bound fixture lifetime even if the test aborts before requesting cleanup.
    server.timeout = 0.1
    deadline = monotonic() + 20
    port_file = Path(sys.argv[1])
    try:
        while monotonic() < deadline and not port_file.with_name("finish").exists():
            server.handle_request()
    finally:
        server.server_close()
        port_file.with_name("finished").touch()
else:
    server.serve_forever()
