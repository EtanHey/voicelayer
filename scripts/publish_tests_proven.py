#!/usr/bin/env python3
"""publish.yml: did the proven build's own CI run `bun test`, with only a release since?

Runs after the release gate. The gate has proved the tagged commit descends from the build the
installed-candidate proof names (release-proofs/<tag>.json, release.gitCommit) and differs from it
only under release-proofs/. This step adds the second fact the bun suite would re-prove: that
build commit's canonical CI run (ci.yml, this repository) really executed `bun test`, meaning the
`Run tests` step of job `test` concluded success on that exact commit. A check merely named
`test` is not enough: the release-only CI shortcut emits a green `test` job whose steps were all
skipped. When both hold, publish.yml skips the audio tool install, the daemon test dependencies
and `bun test` (about 21 of its 22 minutes). Any doubt prints `tests_proven=false` and the
workflow runs the suite exactly as before: this script never fails the job and never turns a
doubt into a skip.

  publish_tests_proven.py --source DIR --tag vX.Y.Z --repo OWNER/NAME [--github-output FILE]

`gh` is used for the API calls (GH overrides the executable, for tests).
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


CI_WORKFLOW = "ci.yml"
CI_WORKFLOW_PATH = ".github/workflows/ci.yml"
CI_JOB = "test"
CI_STEP = "Run tests"


def gh_json(args: list[str]) -> object:
    gh = os.environ.get("GH", "gh")
    api = subprocess.run([gh, "api", *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if api.returncode != 0:
        raise RuntimeError(f"gh api {args[0]} failed: {api.stderr.strip()[:200]}")
    return json.loads(api.stdout)


def bun_test_executed(repo: str, build: str) -> tuple[bool, str]:
    """Did the canonical CI workflow run `bun test` (its `Run tests` step) on exactly this commit?

    A check run merely named `test` is not evidence: the release-only CI shortcut emits a green
    `test` job whose steps were all skipped. So this binds three things: the workflow (ci.yml, from
    this repository), the commit (head_sha == the proven build), and the real step (`Run tests`,
    in the `test` job, concluded success, not skipped).
    """
    runs = gh_json([f"repos/{repo}/actions/workflows/{CI_WORKFLOW}/runs?head_sha={build}&per_page=100"])["workflow_runs"]  # type: ignore[index]
    candidates = [
        run for run in runs
        if run.get("head_sha") == build
        and run.get("path") == CI_WORKFLOW_PATH
        and run.get("status") == "completed"
        and (run.get("repository") or {}).get("full_name") == repo
        and (run.get("head_repository") or {}).get("full_name") == repo
        and isinstance(run.get("id"), int)
    ]
    for run in candidates:
        jobs = gh_json([f"repos/{repo}/actions/runs/{run['id']}/jobs?per_page=100"])["jobs"]  # type: ignore[index]
        for job in jobs:
            if job.get("name") != CI_JOB or job.get("conclusion") != "success":
                continue
            for step in job.get("steps") or []:
                if step.get("name") == CI_STEP and step.get("status") == "completed" and step.get("conclusion") == "success":
                    return True, f"CI run {run['id']} ran `{CI_STEP}` successfully in job `{CI_JOB}`"
    return False, f"no completed {CI_WORKFLOW} run of {build[:8]} shows `{CI_STEP}` succeeding in job `{CI_JOB}` (skipped, missing or not this commit)"


def decide(source: str, tag: str, repo: str) -> tuple[bool, str]:
    if not TAG_RE.match(tag):
        return False, f"{tag!r} is not a release tag"
    head = subprocess.run(["git", "-C", source, "rev-parse", "HEAD"], stdout=subprocess.PIPE, text=True)
    if head.returncode != 0:
        return False, "cannot read the checked-out commit"
    head_sha = head.stdout.strip()
    # The proof is read from the committed blob at HEAD, as a regular file, never through the
    # working tree: a symlink or submodule at that path must not stand in for a proof.
    proof_path = f"release-proofs/{tag}.json"
    entry = subprocess.run(["git", "-C", source, "ls-tree", "HEAD", "--", proof_path], stdout=subprocess.PIPE, text=True)
    if entry.returncode != 0 or not entry.stdout.strip():
        return False, f"no committed {proof_path}"
    if entry.stdout.split()[0] != "100644":
        return False, f"{proof_path} is not a regular committed file"
    blob = subprocess.run(["git", "-C", source, "show", f"HEAD:{proof_path}"], stdout=subprocess.PIPE, text=True)
    try:
        build = json.loads(blob.stdout)["release"]["gitCommit"]
    except (ValueError, KeyError, TypeError) as error:
        return False, f"no readable proof build commit in {proof_path} ({error.__class__.__name__})"
    if not isinstance(build, str) or not COMMIT_RE.match(build):
        return False, "the proof's release.gitCommit is not a full SHA"
    # Defence in depth on top of the gate: the build must be an ancestor, and the diff since it
    # must be only added/modified regular release-only files (stricter than the gate).
    try:
        ok, reason = classify_entries(diff_entries(source, build, head_sha, require_ancestor=True))
    except (OSError, RuntimeError, ValueError) as error:
        return False, f"cannot diff the proven build against the tag ({error})"
    if not ok:
        return False, f"the tag is not a proof-only descendant of {build[:8]}: {reason}"
    try:
        executed, evidence = bun_test_executed(repo, build)
    except (OSError, RuntimeError, ValueError, KeyError, TypeError, AttributeError) as error:
        return False, f"cannot read CI evidence for {build[:8]} ({error})"
    if not executed:
        return False, evidence
    return True, f"{evidence}; the tag is a proof-only descendant ({reason})"


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
