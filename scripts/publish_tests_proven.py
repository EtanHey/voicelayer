#!/usr/bin/env python3
"""publish.yml: has the proven build already passed the `test` job, with only a release since?

Runs after the release gate. The gate has proved the tagged commit descends from the build the
installed-candidate proof names (release-proofs/<tag>.json, release.gitCommit) and differs from it
only under release-proofs/. This step adds the second fact the bun suite would re-prove: that
build commit has a green `test` check run from CI. When both hold, publish.yml skips the audio tool
install and `bun test` (about 21 of its 22 minutes). Any doubt prints `tests_proven=false` and the
workflow runs the suite exactly as before: this script never fails the job and never turns a doubt
into a skip.

  publish_tests_proven.py --source DIR --tag vX.Y.Z --repo OWNER/NAME [--github-output FILE]

`gh` is used for the one API call (GH overrides the executable, for tests).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from release_only_diff import classify_entries, diff_entries  # noqa: E402

COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
TAG_RE = re.compile(r"^v(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?$")


def decide(source: str, tag: str, repo: str) -> tuple[bool, str]:
    if not TAG_RE.match(tag):
        return False, f"{tag!r} is not a release tag"
    proof_path = os.path.join(source, "release-proofs", f"{tag}.json")
    try:
        with open(proof_path, encoding="utf-8") as handle:
            build = json.load(handle)["release"]["gitCommit"]
    except (OSError, ValueError, KeyError, TypeError) as error:
        return False, f"no readable proof build commit in release-proofs/{tag}.json ({error.__class__.__name__})"
    if not isinstance(build, str) or not COMMIT_RE.match(build):
        return False, "the proof's release.gitCommit is not a full SHA"
    head = subprocess.run(["git", "-C", source, "rev-parse", "HEAD"], stdout=subprocess.PIPE, text=True)
    if head.returncode != 0:
        return False, "cannot read the checked-out commit"
    # Defence in depth on top of the gate: the build must be an ancestor, and the diff since it
    # must be only added/modified release-proofs/ files (stricter than the gate: no deletions).
    if subprocess.run(["git", "-C", source, "merge-base", "--is-ancestor", build, "HEAD"]).returncode != 0:
        return False, f"proven build {build[:8]} is not an ancestor of the tagged commit"
    try:
        ok, reason = classify_entries(diff_entries(source, build, head.stdout.strip()))
    except (OSError, RuntimeError, ValueError) as error:
        return False, f"cannot diff the proven build against the tag ({error})"
    if not ok:
        return False, f"the tag is not a proof-only descendant of {build[:8]}: {reason}"

    gh = os.environ.get("GH", "gh")
    api = subprocess.run(
        [gh, "api", f"repos/{repo}/commits/{build}/check-runs?check_name=test&per_page=100"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    if api.returncode != 0:
        return False, f"cannot read check runs for {build[:8]}: {api.stderr.strip()[:200]}"
    try:
        runs = json.loads(api.stdout)["check_runs"]
        green = [
            run for run in runs
            if run.get("name") == "test"
            and run.get("status") == "completed"
            and run.get("conclusion") == "success"
            and (run.get("app") or {}).get("slug") == "github-actions"
        ]
    except (ValueError, KeyError, TypeError, AttributeError):
        return False, "the check-runs answer was not understood"
    if not green:
        return False, f"build {build[:8]} has no green `test` check run"
    return True, f"build {build[:8]} has a green `test` check run and {reason}"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--github-output")
    args = parser.parse_args(argv)
    try:
        proven, reason = decide(args.source, args.tag, args.repo)
    except Exception as error:  # a doubt of any kind runs the suite
        proven, reason = False, f"unexpected {error.__class__.__name__}: {error}"
    print(f"publish-tests-proven: {'SKIP bun test' if proven else 'RUN bun test'}: {reason}")
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as out:
            out.write(f"tests_proven={'true' if proven else 'false'}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
