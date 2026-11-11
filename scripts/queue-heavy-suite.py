#!/usr/bin/env python3
"""Serialize VoiceLayer pre-push suites across worktrees on this Mac."""
import fcntl
import os
from pathlib import Path
import sys


def main():
    if len(sys.argv) < 3 or sys.argv[1] != "--":
        raise ValueError("usage: queue-heavy-suite.py -- COMMAND [ARG ...]")
    home = os.environ.get("HOME", "")
    if not Path(home).is_absolute():
        raise ValueError("absolute HOME required for the shared suite queue")
    lock = Path(home) / ".local/state/voicelayer/heavy-suite.lock"
    lock.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    print(f"VoiceLayer suite queue: WAIT {lock}", file=sys.stderr, flush=True)
    fcntl.flock(fd, fcntl.LOCK_EX)
    print("VoiceLayer suite queue: START", file=sys.stderr, flush=True)
    # Keep custody through exec, including if the shell's parent is interrupted.
    # Never unlink a lock file: waiters must all flock the same inode.
    os.set_inheritable(fd, True)
    command = sys.argv[2:]
    helper = Path(home) / "Gits/golems/.worktrees/hooks-live/scripts/hooks/heavy-suite.py"
    if helper.is_file():
        os.environ["GOLEMS_HEAVY_PRE_PUSH"] = "1"
        command = [sys.executable, str(helper), "--", *command]
    else:
        print("heavy-suite: pinned fleet helper missing; using VoiceLayer serial queue",
              file=sys.stderr, flush=True)
    os.execvp(command[0], command)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        print(f"VoiceLayer suite queue refused: {error}", file=sys.stderr)
        sys.exit(1)
