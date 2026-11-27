#!/usr/bin/env python3
"""Pre-push: may this push skip the Swift and bun suites because it carries only a release?

Called by .githooks/pre-push with git's pre-push stdin (`<local ref> <local sha> <remote ref>
<remote sha>` per line) and argv `<remote name> <remote url>`. Exit 0 means: every pushed ref is
release-only, the release gate passed for it, so the suites would test nothing new. Exit 1 means
run the full suites exactly as before. Every doubt is exit 1: this is a relaxation of a gate, so it
fails closed (no stdin, a deleted ref, a pushed commit that is not the checked-out HEAD, a dirty
tracked tree, a missing bun or base, a gate refusal).

A ref is release-only when either:
  * branch push: the diff from BASE to the pushed commit touches only added or modified regular
    files under `release-proofs/` (scripts/release_only_diff.py), and the release gate AFFIRMS an
    installed-candidate proof for each `release-proofs/vX.Y.Z.json` it carries (a gate that merely
    exits 0, such as its pre-v2.4.0 exemption, is not enough) with only release-only changes since
    the proven build. BASE is the remote's previous tip, which must resolve locally AND be an
    ancestor of the pushed commit (a force-update that drops or reverts code is never skipped); for
    a new branch it is the merge base with <remote>/main, and with no such ref the suites run;
  * tag push `vX.Y.Z`: the same affirmed proof and the same release-only diff from its proven build.

This is never --no-verify: the hook still runs, the docs.local guard ran before this, and the gate
that runs here is the publish workflow's own.
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from release_only_diff import classify_entries, diff_entries  # noqa: E402

GATE_PASS = re.compile(r"PASS: release gate (\S+): proof for build ([0-9a-f]{40})")
ZERO = "0" * 40
TAG_REF = re.compile(r"^refs/tags/(v(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?)$")
PROOF_FILE = re.compile(r"^release-proofs/(v(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?)\.json$")


class Refuse(Exception):
    """This push runs the full suites."""


def git(*args: str) -> str | None:
    result = subprocess.run(["git", *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    return result.stdout.strip() if result.returncode == 0 else None


def release_gate(tag: str, before_tag: bool, head: str) -> None:
    """Run the release gate and require it to have AFFIRMED a proof, not merely exited 0.

    The gate also exits 0 for a tag older than v2.4.0 ("release gate not applied"), which verified
    nothing. Only its `PASS: release gate <tag>: proof for build <sha>` line counts. The build it
    names must be an ancestor of HEAD and the whole change since it must be release-only (added or
    modified regular files under release-proofs/), the same classifier CI and publish use.
    """
    bun = shutil.which("bun")
    if not bun:
        raise Refuse("bun is not on PATH, so the release gate cannot run")
    command = [bun, "scripts/t3-optf5-proof.ts", "release-gate", "--tag", tag, "--repo", "."]
    if before_tag:
        command += ["--before-tag", "HEAD"]
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode != 0:
        reason = (result.stderr.strip() or result.stdout.strip()).splitlines()[-1:] or ["no output"]
        raise Refuse(f"the release gate refused {tag}: {reason[0]}")
    passed = GATE_PASS.search(result.stdout)
    if not passed or passed.group(1) != tag:
        raise Refuse(f"the release gate exited 0 for {tag} without affirming an installed-candidate proof (not applied to this version)")
    build = passed.group(2)
    try:
        ok, reason = classify_entries(diff_entries(".", build, head, require_ancestor=True))
    except (OSError, RuntimeError, ValueError) as error:
        raise Refuse(f"{tag}: cannot diff the proven build {build[:8]} against HEAD ({error})")
    if not ok:
        raise Refuse(f"{tag}: since the proven build {build[:8]}: {reason}")


def check_ref(remote: str, local_ref: str, local_sha: str, remote_ref: str, remote_sha: str, head: str) -> str:
    if local_sha == ZERO:
        raise Refuse(f"{remote_ref}: a ref deletion is not a release push")
    commit = git("rev-parse", "--verify", "-q", f"{local_sha}^{{commit}}")
    if not commit:
        raise Refuse(f"{local_ref}: {local_sha} is not a commit")
    if commit != head:
        raise Refuse(f"{local_ref}: the pushed commit is not the checked-out HEAD (the gate reads the working tree)")

    tag = TAG_REF.match(remote_ref)
    if tag:
        tagged = git("rev-parse", "--verify", "-q", f"refs/tags/{tag.group(1)}^{{commit}}")
        if tagged != head:
            raise Refuse(f"{remote_ref}: the local tag does not resolve to HEAD")
        release_gate(tag.group(1), before_tag=False, head=head)
        return f"{remote_ref}: release gate passed (tagged tree is a proof-only descendant of the proven build)"
    if remote_ref.startswith("refs/tags/"):
        raise Refuse(f"{remote_ref}: not a vMAJOR.MINOR.PATCH release tag")

    if remote_sha != ZERO:
        # An existing branch: the old tip must be known here and be an ancestor of what is pushed.
        # Otherwise the update may drop or revert code the diff never shows (a divergent
        # force-update, or a tip this checkout has never seen).
        if git("cat-file", "-e", f"{remote_sha}^{{commit}}") is None:
            raise Refuse(f"{remote_ref}: the remote tip {remote_sha[:8]} is not in this checkout, so the update cannot be diffed")
        if git("merge-base", "--is-ancestor", remote_sha, commit) is None:
            raise Refuse(f"{remote_ref}: the pushed commit does not contain the remote tip {remote_sha[:8]} (a rewrite or force-update)")
        base = remote_sha
    else:
        # A new branch: everything since its merge base with this remote's main.
        base = git("merge-base", commit, f"refs/remotes/{remote}/main")
        if not base:
            raise Refuse(f"{remote_ref}: no refs/remotes/{remote}/main to diff a new branch against")
    try:
        ok, reason = classify_entries(diff_entries(".", base, commit, require_ancestor=True))
    except (OSError, RuntimeError, ValueError) as error:
        raise Refuse(f"{remote_ref}: cannot read the diff ({error})")
    if not ok:
        raise Refuse(f"{remote_ref}: {reason}")

    changed = git("diff", "--name-only", "--no-renames", f"{base}...{commit}") or ""
    gated = 0
    for path in changed.splitlines():
        proof = PROOF_FILE.match(path)
        if not proof:
            continue
        tag_name = proof.group(1)
        existing = git("rev-parse", "--verify", "-q", f"refs/tags/{tag_name}^{{commit}}")
        if existing is not None and existing != head:
            raise Refuse(f"{path}: tag {tag_name} exists on another commit")
        release_gate(tag_name, before_tag=existing is None, head=head)
        gated += 1
    return f"{remote_ref}: {reason} (vs {base[:8]}); release gate passed for {gated} proof file(s)"


def main(argv: list[str]) -> int:
    remote = argv[1] if len(argv) > 1 else "origin"
    lines = [line.split() for line in sys.stdin.read().splitlines() if line.strip()]
    try:
        if not lines:
            raise Refuse("git sent no refs on stdin")
        if any(len(fields) != 4 for fields in lines):
            raise Refuse("unrecognised pre-push input")
        head = git("rev-parse", "HEAD")
        if not head:
            raise Refuse("cannot read HEAD")
        if git("status", "--porcelain", "--untracked-files=no"):
            raise Refuse("tracked files are modified; the gate reads the working tree")
        reasons = [check_ref(remote, *fields, head) for fields in lines]
    except Refuse as why:
        print(f"[pre-push] full suites run: {why}", file=sys.stderr)
        return 1
    print(
        "[pre-push] RELEASE-ONLY PUSH: the Swift and bun suites are SKIPPED by rule, not by --no-verify. "
        "Only release-proofs/ changes, and the release gate passed: " + "; ".join(reasons),
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
