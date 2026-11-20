#!/usr/bin/env bash
# Release lock: a release step may only act on a commit that is on origin/main.
# Sourced by tag-voicebar-release.sh, release-voicebar.sh and promote-voicebar-release.sh.
#
# require_commit_on_origin_main <script-name> <repo> <commit> <what>
#   Fetches origin main into <repo>, then refuses (prints one line to stderr, returns 1)
#   unless <commit> is an ancestor of origin/main. Fails closed: if main cannot be
#   fetched or the commit is unknown, it refuses. Callers run it before any side effect.
require_commit_on_origin_main() {
    local script="$1" repo="$2" commit="$3" what="$4" full
    if ! git -C "$repo" fetch -q origin main 2>/dev/null; then
        echo "[$script] REFUSED: cannot fetch origin main, so $what $commit cannot be shown to be on main" >&2
        return 1
    fi
    if ! full="$(git -C "$repo" rev-parse --verify -q "$commit^{commit}" 2>/dev/null)"; then
        echo "[$script] REFUSED: $what $commit is not a commit in this repository, so it is not on origin/main" >&2
        return 1
    fi
    if ! git -C "$repo" merge-base --is-ancestor "$full" refs/remotes/origin/main 2>/dev/null; then
        echo "[$script] REFUSED: $what $full is not on origin/main (side-branch commits are never released)" >&2
        return 1
    fi
}

# A main SHA does not authenticate mutable build inputs. Refuse tracked edits and
# nonignored additions as well, before compiling and again at the signer boundary.
require_clean_main_build() {
    local script="$1" repo="$2" commit="$3" status
    require_commit_on_origin_main "$script" "$repo" "$commit" "build commit HEAD" || return 1
    if ! status="$(git -C "$repo" status --porcelain --untracked-files=normal)" || [[ -n "$status" ]]; then
        echo "[$script] REFUSED: source checkout is dirty; build only committed main source" >&2
        return 1
    fi
    if [[ "$(git -C "$repo" rev-parse HEAD)" != "$commit" ]]; then
        echo "[$script] REFUSED: build commit changed during build" >&2
        return 1
    fi
}
