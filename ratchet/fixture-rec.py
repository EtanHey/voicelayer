"""Synthetic rec executable: no device APIs, real-time PCM and exit receipt."""
import json
import os
from pathlib import Path
import signal
import sys
import time
if 'trim' in sys.argv:
    print('Channels       : 1\nSample Rate    : 16000', file=sys.stderr)
    sys.exit(0)
path = Path(os.environ['RATCHET_REC_RECEIPT'])
started, emitted, parent = time.monotonic(), 0, os.getppid()
stopping = False
bytes_per_second, chunk_bytes = 32000, 1024

def receipt(stopped=False):
    temporary = path.with_suffix('.new')
    temporary.write_text(json.dumps(dict(pcm_seconds=emitted / bytes_per_second, stopped=stopped,
                                        elapsed_seconds=time.monotonic() - started)))
    temporary.replace(path)

def stop(*_):
    global stopping
    stopping = True

signal.signal(signal.SIGTERM, stop)
try:
    next_receipt = started
    while not stopping:
        if os.getppid() != parent:
            break
        # Catch up delayed writes using the sample clock, never a fixed sleep
        # added after receipt I/O. At most one 32 ms frame leads elapsed time.
        now = time.monotonic()
        target = (int((now - started) / .032) + 1) * chunk_bytes
        pending = max(0, target - emitted)
        while pending and not stopping:
            written = os.write(1, b'\0' * min(pending, 32000))
            emitted += written
            pending -= written
        if time.monotonic() >= next_receipt:
            receipt()
            next_receipt = time.monotonic() + .25
        time.sleep(max(0, started + emitted / bytes_per_second - time.monotonic()))
except BrokenPipeError:
    pass
finally:
    receipt(stopped=True)
