#!/usr/bin/env bash
set -euo pipefail

# Detect the delivery failure that lost PR #392: GitHub can mark a PR merged
# even when its merge commit lands only on a branch that never reaches main.
# A repository test cannot catch that case because the test changeset is absent
# along with the production changeset. This check inspects GitHub's merged PRs
# independently and proves that every merge commit is reachable from origin/main.

BASE_REF="${MERGED_PRS_BASE_REF:-origin/main}"

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  printf 'ERROR: run this check inside a Git repository.\n' >&2
  exit 2
fi

if ! shallow_repository="$(git rev-parse --is-shallow-repository 2>/dev/null)"; then
  printf 'ERROR: could not determine whether Git history is complete.\n' >&2
  exit 2
fi
if [[ "$shallow_repository" != "false" ]]; then
  printf 'ERROR: ancestry audit requires a complete (non-shallow) Git history.\n' >&2
  exit 2
fi

if [[ "${MERGED_PRS_SKIP_FETCH:-0}" != "1" ]]; then
  if [[ "$BASE_REF" != */* ]]; then
    printf 'ERROR: MERGED_PRS_BASE_REF must be a remote ref such as origin/main.\n' >&2
    exit 2
  fi
  remote="${BASE_REF%%/*}"
  branch="${BASE_REF#*/}"
  if ! git fetch "$remote" \
    "refs/heads/${branch}:refs/remotes/${remote}/${branch}" --quiet; then
    printf 'ERROR: could not refresh %s.\n' "$BASE_REF" >&2
    exit 2
  fi
fi

if ! git rev-parse --verify "${BASE_REF}^{commit}" >/dev/null 2>&1; then
  printf 'ERROR: base ref %s does not resolve to a commit.\n' "$BASE_REF" >&2
  exit 2
fi

if [[ -n "${MERGED_PRS_REPO:-}" ]]; then
  repository="$MERGED_PRS_REPO"
elif ! repository="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"; then
  printf 'ERROR: could not identify the GitHub repository.\n' >&2
  exit 2
fi

if ! merged_prs="$({
  gh api --paginate "repos/${repository}/pulls?state=closed&per_page=100" \
    --jq '.[] | select(.merged_at != null) | [.number, .merge_commit_sha, .html_url, .title] | @tsv'
})"; then
  printf 'ERROR: could not list merged pull requests for %s.\n' "$repository" >&2
  exit 2
fi

unreachable_count=0
while IFS=$'\t' read -r number merge_sha url title; do
  [[ -z "$number" ]] && continue
  if [[ -z "$merge_sha" ]]; then
    printf 'ERROR: merged PR #%s has no merge commit SHA.\n' "$number" >&2
    exit 2
  fi

  if git merge-base --is-ancestor "$merge_sha" "$BASE_REF" 2>/dev/null; then
    continue
  else
    merge_base_status=$?
  fi

  # A freshly fetched base contains every ancestor object. Historical orphan
  # branches may already be deleted, leaving their merge objects unavailable;
  # that absence is itself proof that they are not ancestors of BASE_REF.
  if [[ "$merge_base_status" -ne 1 ]] &&
    git cat-file -e "${merge_sha}^{commit}" 2>/dev/null; then
    printf 'ERROR: could not test merge commit %s from PR #%s.\n' \
      "$merge_sha" "$number" >&2
    exit 2
  fi

  unreachable_count=$((unreachable_count + 1))
  printf -- '- #%s %s %s (%s)\n' "$number" "$merge_sha" "$title" "$url" >&2
done <<< "$merged_prs"

if [[ "$unreachable_count" -gt 0 ]]; then
  if [[ "$unreachable_count" -eq 1 ]]; then
    noun='merged PR is'
  else
    noun='merged PRs are'
  fi
  printf '%s %s not reachable from %s.\n' \
    "$unreachable_count" "$noun" "$BASE_REF" >&2
  exit 1
fi

printf 'All merged PR merge commits are reachable from %s.\n' "$BASE_REF"
