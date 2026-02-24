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
            # Short speaking (7 words ~4s) — stays at 44pt height
            {"type": "state", "state": "speaking", "text": "Hello, how can I help you today?", "_delay": 4},
            {"type": "state", "state": "idle", "_delay": 8},  # 8s idle — collapse should trigger at 5s
            # Recording with speech detection
            {"type": "state", "state": "recording", "mode": "vad", "silence_mode": "standard"},
            {"type": "speech", "detected": True, "_delay": 2},
            {"type": "state", "state": "transcribing"},
            {"type": "transcription", "text": "Can you walk me through how the socket server works?"},
            {"type": "state", "state": "idle", "_delay": 4},
            # Long speaking (33 words ~14s) — expands to 80pt
            {"type": "state", "state": "speaking", "text": "Sure thing. The socket server creates a Unix domain socket at tmp voicelayer sock and broadcasts state changes to all connected clients using newline delimited JSON. Each message is a single line of JSON followed by a newline character.", "_delay": 14},
            {"type": "state", "state": "idle", "_delay": 8},  # 8s idle — collapse again
            # Very long speaking (80 words ~35s) — expands to 80pt
            {"type": "state", "state": "speaking", "text": "Let me walk you through the full architecture. When Claude calls voice speak, the MCP server synthesizes audio using edge TTS, saves it to a ring buffer of twenty files, then broadcasts the speaking state over the Unix socket. The Voice Bar picks this up and starts the teleprompter animation, highlighting each word as it scrolls by. When playback finishes, an idle state is broadcast and the pill shrinks back down. The whole pipeline is non-blocking so Claude can keep working while audio plays in the background.", "_delay": 35},
            {"type": "state", "state": "idle", "_delay": 4},
            # Medium speaking (18 words ~8s) — expands to 80pt
            {"type": "state", "state": "speaking", "text": "Each event has a type field and the Voice Bar parses these to update its display in real time.", "_delay": 8},
            {"type": "state", "state": "idle", "_delay": 8},  # 8s idle — collapse
            # Error
            {"type": "error", "message": "TTS synthesis failed", "recoverable": True},
            {"type": "state", "state": "idle", "_delay": 8},  # 8s idle — collapse
        ]
        while True:  # Loop continuously until client disconnects
            for evt in events:
                delay = evt.get("_delay", 3)
                line = json.dumps({k: v for k, v in evt.items() if k != "_delay"}) + "\n"
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
