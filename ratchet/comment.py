#!/usr/bin/env python3
"""Render SHA-pinned results; optionally upsert one bot-owned PR comment."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from typing import NamedTuple

MARKER = "<!-- voicelayer-ratchet:v1 -->"
ROWS = ("ndjson-partial-write", "socket-isolation", "retranscribe-history-refresh",
        "recents-newest-after-retranscribe", "voice-ask-lock-suspends-timeout")


class InvalidResults(ValueError):
    """An explicitly rejected, untrusted result artifact."""


class Unavailable(NamedTuple):
    reason: str


class Available(NamedTuple):
    baseline: dict
    head: dict


def require(condition, reason):
    if not condition:
        raise InvalidResults(reason)


def read(path, expected_sha):
    data = json.loads(path.read_text())
    require(isinstance(data, list) and len(data) == len(ROWS), "missing/extra rows")
    require(all(isinstance(item, dict) for item in data), "invalid row shape")
    require(all(isinstance(item.get("row"), str) for item in data), "invalid row name")
    require(sorted(item["row"] for item in data) == sorted(ROWS), "row set changed")
    for item in data:
        require(item.get("measured_sha") == expected_sha, "result SHA mismatch")
        require(item.get("kind") == "behavior" and type(item.get("ceiling")) is int
                and item["ceiling"] == 0, "ceiling loosened")
        for key in ("measured_sha", "bug_sha", "fix_sha"):
            require(isinstance(item.get(key), str) and re.fullmatch(r"[0-9a-f]{40}", item[key]), "invalid commit")
        require(type(item.get("value")) is int and item["value"] >= 0, "invalid value")
        require(item.get("status") == ("PASS" if item["value"] == 0 else "FAIL"), "status mismatch")
        if item["row"] in ("socket-isolation", "recents-newest-after-retranscribe"):
            require(isinstance(item.get("overlay_sha256"), str)
                    and re.fullmatch(r"[0-9a-f]{64}", item["overlay_sha256"]), "overlay receipt missing")
    return {item["row"]: item for item in data}


def result(baseline, head, base_sha, head_sha) -> Available | Unavailable:
    try:
        before, after = read(baseline, base_sha), read(head, head_sha)
        for row in ROWS:
            require((before[row]["bug_sha"], before[row]["fix_sha"]) ==
                    (after[row]["bug_sha"], after[row]["fix_sha"]), "row identity mismatch")
        return Available(before, after)
    except FileNotFoundError:
        return Unavailable("missing result artifact")
    except (json.JSONDecodeError, UnicodeDecodeError):
        return Unavailable("malformed result artifact")
    except InvalidResults as error:
        return Unavailable(str(error))


def render(baseline, head, base_sha, head_sha):
    lines = [MARKER, "| row | main baseline | this PR | Δ | ceiling | status |",
             "|---|---:|---:|---:|---:|---|"]
    for row in ROWS:
        before, after = baseline[row], head[row]
        assert (before["bug_sha"], before["fix_sha"]) == (after["bug_sha"], after["fix_sha"])
        seams = {"socket-isolation": "protected-path test seam",
                 "recents-newest-after-retranscribe": "trigger + snapshot + defaults-domain test seams"}
        label = row + ("<br>behavior (overlay: " + seams[row] + ")" if row in seams else "")
        lines.append(f'| {label} | {before["value"]} | {after["value"]} | {after["value"]-before["value"]:+d} | 0 | {after["status"]} |')
    lines += ["", f"Baseline: `{base_sha}` · PR: `{head_sha}`", "",
              "Values count violations, including missing events/sockets/binaries; 0 is PASS."]
    for row in ROWS:
        item = head[row]
        lines.append(f'- `{row}`: bug `{item["bug_sha"]}`, fix `{item["fix_sha"]}`' +
                     (f', overlay SHA-256 `{item["overlay_sha256"]}`' if row in ("socket-isolation", "recents-newest-after-retranscribe") else ""))
    return "\n".join(lines) + "\n"


def signature():
    return ("\n<!-- /voicelayer-ratchet:v1 -->\n\n"
            "— ratchet (worker) · github-actions/automation\n"
            '<!-- golem-id v1 {"seat":"ratchet","role":"worker","harness":"github-actions",'
            '"model":"unknown","model_source":"unavailable","ts":"' +
            datetime.now(timezone.utc).isoformat() + '"} -->\n')


def source_url(repo, run_id):
    require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo), "invalid repository")
    require(type(run_id) is int and run_id > 0, "invalid source run")
    return f"https://github.com/{repo}/actions/runs/{run_id}"


def body_for(outcome, base_sha, head_sha, run_url):
    if isinstance(outcome, Available):
        body = render(outcome.baseline, outcome.head, base_sha, head_sha)
    else:
        body = (f"{MARKER}\nRatchet table unavailable: {outcome.reason}\n\n"
                f"Baseline: `{base_sha}` · PR: `{head_sha}`\n")
    if run_url:
        body += f"\nSource run: {run_url}\n"
    return body + signature()


def api(endpoint, method="GET", *, payload=None, paginate=False):
    command = ["gh", "api", endpoint, "--method", method]
    if paginate:
        command += ["--paginate", "--slurp"]
    if payload is None:
        return json.loads(subprocess.check_output(command))
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json") as file:
        json.dump(payload, file)
        file.flush()
        subprocess.run(command + ["--input", file.name], check=True, stdout=subprocess.DEVNULL)


def context_reason(pr, head_sha):
    if pr["state"] != "open" or pr["head"]["sha"] != head_sha or pr["base"]["ref"] != "main":
        return "superseded or closed PR; preserving pinned table"


def publish(repo, pr, base_sha, head_sha, body, run_url=None):
    pull = f"repos/{repo}/pulls/{pr}"
    reason = context_reason(api(pull), head_sha)
    if reason:
        return reason
    endpoint = f"repos/{repo}/issues/{pr}/comments"
    pages = api(endpoint, paginate=True)
    matches = [c for page in pages for c in page if c["user"]["login"] == "github-actions[bot]"
               and c["body"].startswith(MARKER)]
    assert len(matches) <= 1, "multiple ratchet comments need lead reconciliation"
    if matches:
        endpoint = f'repos/{repo}/issues/comments/{matches[0]["id"]}'
    current = api(pull)
    reason = context_reason(current, head_sha)
    if reason:
        return reason
    if current["base"]["sha"] != base_sha:
        reason = "base advanced during publication"
        body = body_for(Unavailable(reason),
                        current["base"]["sha"], head_sha, run_url)
    api(endpoint, "PATCH" if matches else "POST", payload={"body": body})
    return reason


def main():
    parser = argparse.ArgumentParser()
    for name in ("baseline", "head"):
        parser.add_argument("--" + name, type=Path, required=True)
        parser.add_argument("--" + name + "-sha", required=True)
    parser.add_argument("--repo", default="EtanHey/voicelayer")
    parser.add_argument("--pr", type=int)
    parser.add_argument("--source-run", type=int)
    parser.add_argument("--unavailable-reason")
    args = parser.parse_args()
    outcome = (Unavailable(args.unavailable_reason) if args.unavailable_reason else
               result(args.baseline, args.head, args.baseline_sha, args.head_sha))
    run_url = source_url(args.repo, args.source_run) if args.source_run else None
    body = body_for(outcome, args.baseline_sha, args.head_sha, run_url)
    reason = publish(args.repo, args.pr, args.baseline_sha, args.head_sha, body, run_url) if args.pr else None
    summary = (body_for(Unavailable(reason), args.baseline_sha, args.head_sha,
                        run_url)
               if reason else body)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as file:
            file.write(summary)
    print(summary, end="")


if __name__ == "__main__":
    main()
