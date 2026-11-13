"""Synthetic boot-warmup health endpoint; inference stays in fixture-whisper.py."""
import sys
import os
import json
import time
from socketserver import TCPServer


def receipt(event, **fields):
    path = os.environ.get("RATCHET_WHISPER_SERVER_RECEIPT")
    if path:
        with open(path, "a") as log:
            log.write(json.dumps(dict(event=event, pid=os.getpid(), at=time.monotonic(), **fields)) + "\n")


from http.server import BaseHTTPRequestHandler, HTTPServer


class HealthServer(HTTPServer):
    def server_bind(self):
        # HTTPServer.server_bind calls getfqdn after binding. This numeric-loopback
        # fixture needs no name service, which can block on a hosted runner.
        TCPServer.server_bind(self)
        self.server_name = "127.0.0.1"
        self.server_port = self.server_address[1]
        receipt("bound", port=self.server_port)


class Health(BaseHTTPRequestHandler):
    def do_GET(self):
        receipt("request", path=self.path)
        healthy = self.path == "/health"
        self.send_response(200 if healthy else 404)
        self.end_headers()
        self.wfile.write(b'{"status":"ok"}' if healthy else b"")

    def log_message(self, *_):
        pass


def main():
    receipt("python-started", executable=sys.executable, argv=sys.argv)
    if "--help" in sys.argv or "--version" in sys.argv:
        print("ratchet synthetic health-only whisper-server")
        return
    port = int(sys.argv[sys.argv.index("--port") + 1])
    receipt("binding", port=port)
    try:
        with HealthServer(("127.0.0.1", port), Health) as server:
            receipt("listening", port=port)
            server.serve_forever()
    except Exception as error:
        receipt("failed", error=type(error).__name__, detail=str(error))
        raise


if __name__ == "__main__":
    main()
