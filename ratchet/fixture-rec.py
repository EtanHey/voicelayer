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
started, chunks, parent = time.monotonic(), 0, os.getppid()

def receipt(stopped=False):
    temporary = path.with_suffix('.new')
    temporary.write_text(json.dumps(dict(pcm_seconds=chunks * .032, stopped=stopped,
                                        elapsed_seconds=time.monotonic() - started)))
    temporary.replace(path)

def stop(*_):
    receipt(stopped=True)
    sys.exit(0)

signal.signal(signal.SIGTERM, stop)
try:
    while True:
        if os.getppid() != parent:
            stop()
        os.write(1, b'\0' * 1024)
        chunks += 1
        receipt()
        time.sleep(.032)
except BrokenPipeError:
    stop()
