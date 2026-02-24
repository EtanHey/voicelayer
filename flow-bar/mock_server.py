#!/usr/bin/env python3
"""Mock VoiceLayer socket server for testing Voice Bar.

Cycles through voice states continuously so you can verify
the pill UI updates correctly.

Usage:
    python3 mock_server.py
    # Then run: cd flow-bar && swift run
"""

import socket
import json
import os
import time

SOCK = "/tmp/voicelayer.sock"
if os.path.exists(SOCK):
    os.unlink(SOCK)

srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(SOCK)
srv.listen(1)
print(f"Listening on {SOCK}  --  run Voice Bar now")

while True:
    conn, _ = srv.accept()
    print("Client connected")
    try:
        events = [
            # Short speaking — teleprompter fits in one view
            {"type": "state", "state": "speaking", "text": "Hello, how can I help you today?"},
            {"type": "state", "state": "idle", "_delay": 6},
            # Recording with speech detection
            {"type": "state", "state": "recording", "mode": "vad", "silence_mode": "standard"},
            {"type": "speech", "detected": True, "_delay": 2},
            {"type": "state", "state": "transcribing"},
            {"type": "transcription", "text": "Can you walk me through how the socket server works?"},
            {"type": "state", "state": "idle"},
            # Long speaking — teleprompter scrolls through words
            {"type": "state", "state": "speaking", "text": "Sure thing. The socket server creates a Unix domain socket at tmp voicelayer sock and broadcasts state changes to all connected clients using newline delimited JSON"},
            {"type": "state", "state": "idle", "_delay": 12},
            # Another medium speaking
            {"type": "state", "state": "speaking", "text": "Each event has a type field and the Voice Bar parses these to update its display in real time"},
            {"type": "state", "state": "idle", "_delay": 8},
            # Error
            {"type": "error", "message": "TTS synthesis failed", "recoverable": True},
            {"type": "state", "state": "idle"},
        ]
        while True:  # Loop continuously until client disconnects
            for evt in events:
                delay = evt.get("_delay", 3)
                line = json.dumps(evt) + "\n"
                conn.sendall(line.encode())
                print(f"  -> {line.strip()}")
                time.sleep(delay)

                # Check for incoming commands (non-blocking)
                conn.setblocking(False)
                try:
                    data = conn.recv(4096)
                    if data:
                        for cmd_line in data.decode().strip().split("\n"):
                            print(f"  <- {cmd_line}")
                except BlockingIOError:
                    pass
                conn.setblocking(True)

    except BrokenPipeError:
        print("Client disconnected")
    finally:
        conn.close()
