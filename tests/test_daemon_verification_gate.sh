#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/daemon-verification-gate.yml"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT

# Hooks may export Git state; never let fixture commits target the caller's repo.
for git_var in $(env | sed -n 's/^\(GIT_[^=]*\)=.*/\1/p'); do
    unset "$git_var"
done
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

fail() {
    cat "$FIXTURE/gate.out" >&2
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

# Execute the actual gate, including its path filter and runtime marker checks.
awk '
    /- name: Check runtime verification marker/ { step = 1; next }
    step && /^        run: \|/ { body = 1; next }
    body && /^          / { sub(/^          /, ""); print; next }
    body && /^$/ { print; next }
    body { exit }
' "$WORKFLOW" > "$FIXTURE/gate.sh"
test -s "$FIXTURE/gate.sh"
grep -q 'fetch-depth: 0' "$WORKFLOW"

git init -q "$FIXTURE/repo"
cd "$FIXTURE/repo"
git config user.name 'Gate Fixture'
git config user.email 'gate-fixture@example.invalid'
git config core.hooksPath /dev/null
printf 'initial\n' > README
git add README
git commit -qm 'Initial fixture'
git branch -M main
git checkout -qb pr
printf 'PR documentation\n' >> README
git commit -qam 'Documentation-only PR'
DOC_HEAD="$(git rev-parse HEAD)"
git checkout -q main
mkdir flow-bar
printf 'main release\n' > flow-bar/x
git add flow-bar/x
git commit -qm 'Main advances after PR branches'
BASE_SHA="$(git rev-parse HEAD)"
export BASE_SHA

run_gate() {
    HEAD_SHA="$1" PR_BODY="$2" TMPDIR="$FIXTURE" \
        bash "$FIXTURE/gate.sh" > "$FIXTURE/gate.out" 2>&1
}

# Show the old endpoint diff incorrectly attributes main's release to the PR.
git diff --name-only "$BASE_SHA" "$DOC_HEAD" > "$FIXTURE/old-files"
grep -Fxq 'flow-bar/x' "$FIXTURE/old-files"
printf 'PASS: old endpoint diff reproduces the stale-base false positive\n'

run_gate "$DOC_HEAD" '' || fail 'documentation-only stale-base PR must pass'
grep -Fq 'No daemon/socket/MCP files changed' "$FIXTURE/gate.out"
printf 'PASS: documentation-only stale-base PR needs no runtime marker\n'

git checkout -q pr
mkdir flow-bar
printf 'PR daemon change\n' > flow-bar/pr-change
git add flow-bar/pr-change
git commit -qm 'PR really changes VoiceBar'
DAEMON_HEAD="$(git rev-parse HEAD)"

if run_gate "$DAEMON_HEAD" ''; then
    fail 'real VoiceBar change must require a runtime marker'
fi
grep -Fxq -- '- flow-bar/pr-change' "$FIXTURE/gate.out"
grep -Fq 'Missing runtime verification marker.' "$FIXTURE/gate.out"
if grep -Fxq -- '- flow-bar/x' "$FIXTURE/gate.out"; then
    fail 'main-only release file must not be flagged alongside the PR change'
fi
printf 'PASS: real VoiceBar change is flagged without main-only files\n'

if run_gate "$DAEMON_HEAD" "Verified-Runtime: $DOC_HEAD"; then
    fail 'runtime marker for an older head must fail'
fi
grep -Fq 'Missing runtime verification marker.' "$FIXTURE/gate.out"
printf 'PASS: stale runtime marker is rejected\n'

run_gate "$DAEMON_HEAD" "Verified-Runtime: $DAEMON_HEAD" \
    || fail 'runtime marker for the actual head must pass'
grep -Fq "Found runtime verification marker for head sha $DAEMON_HEAD." "$FIXTURE/gate.out"
printf 'PASS: exact-head runtime marker is accepted\n'
