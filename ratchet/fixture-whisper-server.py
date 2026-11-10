"""Synthetic boot-warmup health endpoint; inference stays in fixture-whisper.py."""
from http.server import BaseHTTPRequestHandler, HTTPServer
import sys


class Health(BaseHTTPRequestHandler):
    def do_GET(self):
        healthy = self.path == "/health"
        self.send_response(200 if healthy else 404)
        self.end_headers()
        self.wfile.write(b'{"status":"ok"}' if healthy else b"")

    def log_message(self, *_):
        pass


port = int(sys.argv[sys.argv.index("--port") + 1])
HTTPServer(("127.0.0.1", port), Health).serve_forever()
