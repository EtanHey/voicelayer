#!/usr/bin/env python3
"""External deadline for Bun tests: its promise matcher can block the event loop."""
import argparse
import os
import signal
import subprocess
import time
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--seconds', type=float, default=30)
parser.add_argument('--log', type=Path, required=True)
parser.add_argument('command', nargs=argparse.REMAINDER)
args = parser.parse_args()
command = args.command[1:] if args.command[:1] == ['--'] else args.command
if not command or args.seconds <= 0:
    parser.error('a command and a positive deadline are required')
args.log.parent.mkdir(parents=True, exist_ok=True)
started = time.monotonic()
with args.log.open('w') as output:
    child = subprocess.Popen(command, env=os.environ.copy(), stdout=output,
                             stderr=subprocess.STDOUT, start_new_session=True)
    try:
        code = child.wait(timeout=args.seconds)
    except subprocess.TimeoutExpired:
        code = 124
    finally:
        # Exact group created above: also reap fixture descendants on failure.
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.wait()
elapsed = time.monotonic() - started
print(f'exit={code} elapsed_seconds={elapsed:.3f} pid={child.pid} reaped=true log={args.log}', flush=True)
raise SystemExit(code)
