"""Stream TLC -continue without retaining repeated safety counterexample traces.

The supervised process group includes this wrapper and TLC. Preserve each actual
named error, all temporal counterexample states, and TLC's own counts/depth.
"""
import collections
import os
import re
import subprocess
import sys
from f5_checks import temporal_failure

child = subprocess.Popen(sys.argv[1:], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         text=True, errors="replace", env=os.environ)
violations = collections.Counter()
temporal = False
lines_seen = 0
for line in child.stdout:
    lines_seen += 1
    diagnostic = re.search(r"CrossKill:(\w+)", line) if "CrossKill:" in line else None
    if diagnostic:
        key = diagnostic[1]
        violations["diagnostic:" + key] += 1
        if violations["diagnostic:" + key] == 1:
            print(line, end="", flush=True)
        continue
    match = re.search(r"Invariant (\w+) is violated", line) if "Invariant " in line else None
    if match:
        violations[match[1]] += 1
        if violations[match[1]] == 1:
            print(line, end="", flush=True)
    else:
        temporal |= (("Error: Temporal " in line and temporal_failure(line)) or "unexpected exception" in line)
        if not temporal and "Error: The behavior up to this point is:" in line:
            continue
        if temporal or lines_seen <= 24 or any(marker in line for marker in (
            "Error:", "states generated,", "The depth of", "Model checking completed.", "Progress(", "Finished in")):
            print(line, end="", flush=True)
status = child.wait()
print("Cross-run diagnostic occurrences: " + repr(dict(violations)), flush=True)
sys.exit(status if status >= 0 else 128 - status)
