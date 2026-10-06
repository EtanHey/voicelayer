#!/usr/bin/env python3
"""Render SHA-pinned results; optionally upsert one bot-owned PR comment."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import subprocess
import tempfile

MARKER = "<!-- voicelayer-ratchet:v1 -->"
ROWS = ("ndjson-partial-write", "socket-isolation", "retranscribe-history-refresh", "voice-ask-lock-suspends-timeout")


def read(path, expected_sha):
    data = json.loads(path.read_text())
    assert isinstance(data, list) and len(data) == len(ROWS), "missing/extra rows"
    assert sorted(item["row"] for item in data) == sorted(ROWS), "row set changed"
    for item in data:
        assert item["measured_sha"] == expected_sha, "result SHA mismatch"
        assert item["kind"] == "behavior" and item["ceiling"] == 0, "ceiling loosened"
        for key in ("measured_sha", "bug_sha", "fix_sha"):
            assert re.fullmatch(r"[0-9a-f]{40}", item[key]), "invalid commit"
        assert type(item["value"]) is int and item["value"] >= 0, "invalid value"
        assert item["status"] == ("PASS" if item["value"] == 0 else "FAIL"), "status mismatch"
        if item["row"] == "socket-isolation":
            assert re.fullmatch(r"[0-9a-f]{64}", item["overlay_sha256"]), "overlay receipt missing"
    return {item["row"]: item for item in data}


def render(baseline, head, base_sha, head_sha):
    lines = [MARKER, "| row | main baseline | this PR | Δ | ceiling | status |",
             "|---|---:|---:|---:|---:|---|"]
    for row in ROWS:
        before, after = baseline[row], head[row]
        assert (before["bug_sha"], before["fix_sha"]) == (after["bug_sha"], after["fix_sha"])
        label = row + ("<br>behavior (overlay: protected-path test seam)" if row == "socket-isolation" else "")
        lines.append(f'| {label} | {before["value"]} | {after["value"]} | {after["value"]-before["value"]:+d} | 0 | {after["status"]} |')
    lines += ["", f"Baseline: `{base_sha}` · PR: `{head_sha}`", "",
              "Values count violations, including missing events/sockets/binaries; 0 is PASS."]
    for row in ROWS:
        item = head[row]
        lines.append(f'- `{row}`: bug `{item["bug_sha"]}`, fix `{item["fix_sha"]}`' +
                     (f', overlay SHA-256 `{item["overlay_sha256"]}`' if row == "socket-isolation" else ""))
    lines += ["", "<!-- /voicelayer-ratchet:v1 -->", "",
              "— ratchet (worker) · github-actions/automation",
              '<!-- golem-id v1 {"seat":"ratchet","role":"worker","harness":"github-actions","model":"unknown","model_source":"unavailable","ts":"' + datetime.now(timezone.utc).isoformat() + '"} -->']
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser()
    for name in ("baseline", "head"):
        parser.add_argument("--" + name, type=Path, required=True)
        parser.add_argument("--" + name + "-sha", required=True)
    parser.add_argument("--repo", default="EtanHey/voicelayer")
    parser.add_argument("--pr", type=int)
    args = parser.parse_args()
    body = render(read(args.baseline, args.baseline_sha), read(args.head, args.head_sha),
                  args.baseline_sha, args.head_sha)
    if args.pr is None:
        print(body, end="")
        return
    endpoint = f"repos/{args.repo}/issues/{args.pr}/comments"
    pages = json.loads(subprocess.check_output(["gh", "api", endpoint, "--paginate", "--slurp"]))
    matches = [c for page in pages for c in page if c["user"]["login"] == "github-actions[bot]"
               and c["body"].startswith(MARKER)]
    assert len(matches) <= 1, "multiple ratchet comments need lead reconciliation"
    if matches:
        endpoint = f'repos/{args.repo}/issues/comments/{matches[0]["id"]}'
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json") as payload:
        json.dump({"body": body}, payload)
        payload.flush()
        subprocess.run(["gh", "api", endpoint, "--method", "PATCH" if matches else "POST",
                        "--input", payload.name], check=True, stdout=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
