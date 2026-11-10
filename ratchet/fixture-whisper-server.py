"""Synthetic boot-warmup health endpoint; inference stays in fixture-whisper.py."""
import sys
import os
import json
import time
from pathlib import Path


def receipt(event, **fields):
    path = os.environ.get("RATCHET_WHISPER_SERVER_RECEIPT")
    if path:
        with open(path, "a") as log:
            log.write(json.dumps(dict(event=event, pid=os.getpid(), at=time.monotonic(), **fields)) + "\n")


receipt("python-started", executable=sys.executable, argv=sys.argv)
from http.server import BaseHTTPRequestHandler, HTTPServer


class Health(BaseHTTPRequestHandler):
    def do_GET(self):
        receipt("request", path=self.path)
        healthy = self.path == "/health"
        self.send_response(200 if healthy else 404)
        self.end_headers()
        self.wfile.write(b'{"status":"ok"}' if healthy else b"")

    def log_message(self, *_):
        pass


port = int(sys.argv[sys.argv.index("--port") + 1])
receipt("binding", port=port)
server = HTTPServer(("127.0.0.1", port), Health)
receipt("listening", port=port)
server.serve_forever()
