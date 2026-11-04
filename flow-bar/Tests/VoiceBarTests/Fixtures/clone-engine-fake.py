"""Fake engine only: ephemeral HTTP, no audio, models, microphone or live files."""
import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import sys

class Health(BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"status": "ok", "pid": os.getpid(), "model_loaded": False}).encode()
        self.send_response(200 if self.headers.get("Authorization") == "Bearer fake-engine-token" else 401)
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass

server = HTTPServer(("127.0.0.1", 0), Health)
Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
