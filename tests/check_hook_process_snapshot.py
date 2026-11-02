#!/usr/bin/env python3
"""Exercise the harness's actual process snapshot/assertion with raw ps bytes."""

import ast
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    script = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).with_name("test_hook_orphan_daemon.sh")
    python = script.read_text().split("<<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
    tree = ast.parse(python)
    statements = [node for node in ast.walk(tree) if isinstance(node, ast.Assign)
                  and any(isinstance(target, ast.Name) and target.id == "processes" for target in node.targets)]
    assertions = [node for node in ast.walk(tree) if isinstance(node, ast.Assert)
                  and isinstance(node.msg, ast.Constant) and node.msg.value == "process with RUN_DIR remains"]
    if len(statements) != 1 or len(assertions) != 1:
        raise RuntimeError("process snapshot and leak assertion must each occur exactly once")
    check = compile(ast.Module(body=[statements[0], assertions[0]], type_ignores=[]), str(script), "exec")
    with tempfile.TemporaryDirectory(prefix="hook-ps-") as temp:
        directory = Path(temp)
        raw = directory / "snapshot"
        ps = directory / "ps"
        ps.write_text(f"#!{sys.executable}\nfrom pathlib import Path\nimport sys\nsys.stdout.buffer.write(Path({str(raw)!r}).read_bytes())\n")
        ps.chmod(0o700)
        previous = os.environ.get("PATH", "")
        os.environ["PATH"] = str(directory) + os.pathsep + previous
        try:
            run_dir = directory / "voicelayer-run-tests.42"
            for label, payload, leak in [
                ("ordinary", b"7 foreign-process\n", False),
                ("foreign non-UTF8 argv", b"7 foreign-\xff-process\n", False),
                ("leak after non-UTF8 argv", b"7 foreign-\xff\n42 " + os.fsencode(run_dir) + b"\n", True),
                ("leak before non-UTF8 argv", b"42 " + os.fsencode(run_dir) + b"\n7 foreign-\xff\n", True),
            ]:
                raw.write_bytes(payload)
                try:
                    exec(check, {"subprocess": subprocess, "run_dir": run_dir})
                except AssertionError as error:
                    if not leak or str(error) != "process with RUN_DIR remains":
                        raise
                else:
                    if leak:
                        raise AssertionError(f"{label}: leaked run escaped the real assertion")
                print(f"PASS snapshot: {label}; leaked-run detection={leak}", flush=True)
        finally:
            os.environ["PATH"] = previous


if __name__ == "__main__":
    main()
