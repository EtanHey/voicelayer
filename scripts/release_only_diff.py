#!/usr/bin/env python3
"""Is a git diff release-only? One allow-list, shared by the pre-push hook, CI and publish.yml.

The allow-list is the rule scripts/t3-optf5-proof.ts `isProofOnlyPath` already enforces for a
proof-only descendant of a proven build (the release gate, publish.yml's first step):
every changed path is under `release-proofs/`, except `release-proofs/proof-hosts.json`, which is
reviewed code ("a proof-only commit may not change this file"). There is deliberately nothing
else: not package.json, not a lockfile, not a doc. A parity test
(src/__tests__/release-only-diff.test.ts) keeps this file and the TypeScript rule identical.

On top of the path rule, a release-only diff must be non-empty and every entry must be an
Added or Modified REGULAR file (git mode 100644). A deleted or type-changed entry, a symlink
(120000), a submodule (160000) or an executable (100755) is never release-only (renames are
reported as delete + add, so a rename out of another directory is refused too). Files the
root `bun test` discovers by name (*.test.ts, *_spec.js, ...) are also refused: under
release-proofs/ they would be code that runs in the very suite the shortcut skips.

Usage:
  release_only_diff.py --base BASE --head HEAD [--repo DIR] [--github-output FILE] [--ancestor]
      Diffs BASE...HEAD (changes since their merge base, the way a PR's file list is formed).
      With --ancestor, BASE must be an ancestor of HEAD (else exit 2) and BASE..HEAD is diffed:
      used where the diff must be the exact change a ref update makes.
      Exit 0 = release-only, 1 = not release-only (the reason is on stderr), 2 = could not tell.
      Anything other than exit 0 means "run everything".
  release_only_diff.py --classify-paths
      Reads newline-separated paths on stdin and prints `allowed` or `refused` per path
      (used by the parity test).
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys

PROOF_DIR = "release-proofs"
PROOF_HOSTS_FILE = f"{PROOF_DIR}/proof-hosts.json"
ALLOWED_STATUSES = frozenset({"A", "M"})
REGULAR_FILE_MODE = "100644"
# Mirrors BUN_TEST_FILE in scripts/t3-optf5-proof.ts: what the root `bun test` discovers by name.
BUN_TEST_FILE = re.compile(r"[._](?:test|spec)\.[cm]?[jt]sx?$", re.IGNORECASE)


def is_release_only_path(path: str) -> bool:
    """The exact rule of isProofOnlyPath in scripts/t3-optf5-proof.ts."""
    return path.startswith(f"{PROOF_DIR}/") and path != PROOF_HOSTS_FILE and not BUN_TEST_FILE.search(path)


def parse_raw_z(raw: bytes) -> list[tuple[str, str, str]]:
    """Parse `git diff --raw -z --no-renames` into (status, path, new mode) triples."""
    fields = raw.split(b"\0")
    if fields and fields[-1] == b"":
        fields.pop()
    if len(fields) % 2 != 0:
        raise ValueError("unparseable git diff --raw -z output")
    entries = []
    for i in range(0, len(fields), 2):
        meta = fields[i].decode("ascii", "replace").split()
        if len(meta) != 5 or not meta[0].startswith(":"):
            raise ValueError("unparseable git diff --raw -z entry")
        entries.append((meta[4], fields[i + 1].decode("utf-8", "surrogateescape"), meta[1]))
    return entries


def classify_entries(entries: list[tuple[str, str, str]]) -> tuple[bool, str]:
    if not entries:
        return False, "the diff is empty: nothing to classify as release-only"
    for status, path, mode in entries:
        if status not in ALLOWED_STATUSES:
            return False, f"{path} is {status!r} (only added or modified files can be release-only)"
        if mode != REGULAR_FILE_MODE:
            return False, f"{path} has git mode {mode} (only regular non-executable files can be release-only: no symlink, submodule or executable)"
        if not is_release_only_path(path):
            return False, f"{path} is outside {PROOF_DIR}/ (or is {PROOF_HOSTS_FILE}, or a file `bun test` discovers): not release-only"
    return True, f"{len(entries)} file(s), all under {PROOF_DIR}/"


def is_ancestor(repo: str, ancestor: str, descendant: str) -> bool:
    return subprocess.run(
        ["git", "-C", repo, "merge-base", "--is-ancestor", ancestor, descendant],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    ).returncode == 0


def diff_entries(repo: str, base: str, head: str, require_ancestor: bool = False) -> list[tuple[str, str, str]]:
    """Entries changed from BASE to HEAD.

    Default: BASE...HEAD (since the merge base), which is how a PR's file list is formed. With
    require_ancestor, BASE must resolve and be an ancestor of HEAD, and BASE..HEAD is diffed: the
    exact change a ref update or a release makes. A divergent BASE is an error, never a guess, so a
    force-update that drops or reverts code cannot look proof-only.
    """
    if require_ancestor:
        if not is_ancestor(repo, base, head):
            raise RuntimeError(f"{base} is not an ancestor of {head}")
        spec = [base, head]
    else:
        spec = [f"{base}...{head}"]
    result = subprocess.run(
        ["git", "-C", repo, "diff", "--raw", "-z", "--no-renames", "--no-abbrev", *spec],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=None,
    )
    if result.returncode != 0:
        raise RuntimeError(f"git diff {' '.join(spec)} failed: {result.stderr.decode(errors='replace').strip()}")
    return parse_raw_z(result.stdout)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base")
    parser.add_argument("--head")
    parser.add_argument("--repo", default=".")
    parser.add_argument("--github-output", help="append `release_only=true|false` to this file when the answer is known")
    parser.add_argument("--ancestor", action="store_true", help="require BASE to be an ancestor of HEAD and diff BASE..HEAD")
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
        ok, reason = classify_entries(diff_entries(args.repo, args.base, args.head, require_ancestor=args.ancestor))
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
