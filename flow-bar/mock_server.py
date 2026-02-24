#!/usr/bin/env python3
"""Mock VoiceLayer socket server for testing Voice Bar.

Cycles through voice states every 2 seconds so you can verify
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
            {"type": "state", "state": "speaking", "text": "Hello, how can I help?"},
            {"type": "state", "state": "idle"},
            {"type": "state", "state": "recording", "mode": "vad", "silence_mode": "standard"},
            {"type": "speech", "detected": True},
            {"type": "state", "state": "transcribing"},
            {"type": "transcription", "text": "Can you explain this code?"},
            {"type": "state", "state": "idle"},
            {"type": "state", "state": "speaking", "text": "Sure, let me walk you through it..."},
            {"type": "state", "state": "idle"},
            {"type": "error", "message": "TTS synthesis failed", "recoverable": True},
            {"type": "state", "state": "idle"},
        ]
        for evt in events:
            line = json.dumps(evt) + "\n"
            conn.sendall(line.encode())
            print(f"  -> {line.strip()}")
            time.sleep(2)

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
