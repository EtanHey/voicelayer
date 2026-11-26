#!/usr/bin/env python3
"""Is a git diff release-only? One allow-list, shared by the pre-push hook, CI and publish.yml.

The allow-list is the rule scripts/t3-optf5-proof.ts `isProofOnlyPath` already enforces for a
proof-only descendant of a proven build (the release gate, publish.yml's first step):
every changed path is under `release-proofs/`, except `release-proofs/proof-hosts.json`, which is
reviewed code ("a proof-only commit may not change this file"). There is deliberately nothing
else: not package.json, not a lockfile, not a doc. A parity test
(src/__tests__/release-only-diff.test.ts) keeps this file and the TypeScript rule identical.

On top of the path rule, a release-only diff must be non-empty and every entry must be an
Added or Modified file. A deleted or type-changed entry is never release-only (renames are
reported as delete + add, so a rename out of another directory is refused too).

Usage:
  release_only_diff.py --base BASE --head HEAD [--repo DIR] [--github-output FILE]
      Diffs BASE...HEAD (changes since their merge base, the way a PR's file list is formed).
      Exit 0 = release-only, 1 = not release-only (the reason is on stderr), 2 = could not tell.
      Anything other than exit 0 means "run everything".
  release_only_diff.py --classify-paths
      Reads newline-separated paths on stdin and prints `allowed` or `refused` per path
      (used by the parity test).
"""
from __future__ import annotations

import argparse
import subprocess
import sys

PROOF_DIR = "release-proofs"
PROOF_HOSTS_FILE = f"{PROOF_DIR}/proof-hosts.json"
ALLOWED_STATUSES = frozenset({"A", "M"})


def is_release_only_path(path: str) -> bool:
    """The exact rule of isProofOnlyPath in scripts/t3-optf5-proof.ts."""
    return path.startswith(f"{PROOF_DIR}/") and path != PROOF_HOSTS_FILE


def parse_name_status_z(raw: bytes) -> list[tuple[str, str]]:
    """Parse `git diff --name-status -z --no-renames` output into (status, path) pairs."""
    fields = raw.split(b"\0")
    if fields and fields[-1] == b"":
        fields.pop()
    if len(fields) % 2 != 0:
        raise ValueError("unparseable git diff --name-status -z output")
    return [
        (fields[i].decode("utf-8", "surrogateescape"), fields[i + 1].decode("utf-8", "surrogateescape"))
        for i in range(0, len(fields), 2)
    ]


def classify_entries(entries: list[tuple[str, str]]) -> tuple[bool, str]:
    if not entries:
        return False, "the diff is empty: nothing to classify as release-only"
    for status, path in entries:
        if status not in ALLOWED_STATUSES:
            return False, f"{path} is {status!r} (only added or modified files can be release-only)"
        if not is_release_only_path(path):
            return False, f"{path} is outside {PROOF_DIR}/ (or is {PROOF_HOSTS_FILE}): not release-only"
    return True, f"{len(entries)} file(s), all under {PROOF_DIR}/"


def diff_entries(repo: str, base: str, head: str) -> list[tuple[str, str]]:
    result = subprocess.run(
        ["git", "-C", repo, "diff", "--name-status", "-z", "--no-renames", f"{base}...{head}"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=None,
    )
    if result.returncode != 0:
        raise RuntimeError(f"git diff {base}...{head} failed: {result.stderr.decode(errors='replace').strip()}")
    return parse_name_status_z(result.stdout)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base")
    parser.add_argument("--head")
    parser.add_argument("--repo", default=".")
    parser.add_argument("--github-output", help="append `release_only=true|false` to this file when the answer is known")
    parser.add_argument("--classify-paths", action="store_true")
    args = parser.parse_args(argv)

    if args.classify_paths:
        for line in sys.stdin.read().split("\n"):
            if line:
                print("allowed" if is_release_only_path(line) else "refused")
        return 0
    if not args.base or not args.head:
        parser.error("--base and --head are required")

    try:
        ok, reason = classify_entries(diff_entries(args.repo, args.base, args.head))
    except (OSError, RuntimeError, ValueError) as error:
        print(f"release-only-diff: cannot tell ({error}); run everything", file=sys.stderr)
        return 2
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as out:
            out.write(f"release_only={'true' if ok else 'false'}\n")
    print(f"release-only-diff: {'RELEASE-ONLY' if ok else 'NOT release-only'}: {reason}", file=sys.stderr)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
