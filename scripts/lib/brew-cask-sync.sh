#!/usr/bin/env bash
# Drift-proof Homebrew cask sync helpers.
#
# AIDEV-NOTE: This library exists because `brew upgrade --cask` is UNSAFE on a
# machine whose /Applications bundle was replaced out-of-band. Homebrew reads the
# uninstall stanza from the OLD version's saved cask in Caskroom/<name>/.metadata,
# so a pre-fix `delete:` recipe still shells out to `sudo rm` — which aborts with
# no TTY over ssh, after the services and LaunchAgents are already destroyed.
# On 2026-08-19 that left the main Mac with VoiceBar down and no LaunchAgents.
#
# The safe move on drift is: clear the stale (user-owned) Caskroom registration,
# then `brew install --cask --force` to ADOPT the app already on disk. That never
# runs an old uninstall recipe and never needs root.
#
# Sourceable and side-effect free: sourcing defines functions only.
# Every function is prefixed `bcs_` and takes its target explicitly, so BrainLayer
# (BrainBar) can source this same file for its own cask.

# --- output -----------------------------------------------------------------

bcs_log() {
    printf '[brew-cask-sync] %s\n' "$*"
}

bcs_err() {
    printf '[brew-cask-sync] ERROR: %s\n' "$*" >&2
}

# AIDEV-NOTE: `typeset -f`, not `declare -F`. zsh's `declare -F <name>` succeeds
# for an UNDEFINED function, so the bash idiom silently calls a missing run_cmd.
# The M1's non-interactive ssh shell is zsh, which is exactly where this library
# has to work unattended.
bcs_function_exists() {
    typeset -f "$1" >/dev/null 2>&1
}

# Defer to the caller's run_cmd (which honours --dry-run) when one exists.
bcs_run() {
    if bcs_function_exists run_cmd; then
        run_cmd "$@"
    else
        printf '+ %s\n' "$*"
        "$@"
    fi
}

# --- brew resolution --------------------------------------------------------

# Absolute paths first: bare `brew` is not on the M1's non-interactive ssh PATH
# and silently reads as "not installed".
bcs_brew_bin() {
    if [[ -n "${BREW_CASK_SYNC_BREW_BIN:-}" ]]; then
        printf '%s\n' "$BREW_CASK_SYNC_BREW_BIN"
        return 0
    fi
    local candidate
    for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    if command -v brew >/dev/null 2>&1; then
        command -v brew
        return 0
    fi
    return 1
}

bcs_require_brew() {
    if ! bcs_brew_bin >/dev/null; then
        bcs_err "Homebrew not found. Expected /opt/homebrew/bin/brew (Apple silicon) or /usr/local/bin/brew."
        return 1
    fi
}

# Read-only brew query. Always runs, even under --dry-run: detection must be real.
bcs_brew() {
    local brew_bin
    brew_bin="$(bcs_brew_bin)" || return 1
    HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 "$brew_bin" "$@"
}

# True when the caller's run_cmd only prints. Post-conditions cannot be asserted
# in that mode, because nothing was actually done.
bcs_commands_are_simulated() {
    if bcs_function_exists bcs_caller_simulates_commands; then
        bcs_caller_simulates_commands
        return
    fi
    return 1
}

# Mutating brew call, routed through run_cmd so --dry-run prints instead of acts.
bcs_brew_run() {
    local brew_bin
    brew_bin="$(bcs_brew_bin)" || return 1
    bcs_run env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 "$brew_bin" "$@"
}

# --- naming -----------------------------------------------------------------

# etanhey/layers/voicebar -> voicebar
bcs_cask_name() {
    printf '%s\n' "${1##*/}"
}

# etanhey/layers/voicebar -> etanhey/layers   (empty for a bare token)
bcs_cask_tap() {
    local token="$1"
    if [[ "$token" == */*/* ]]; then
        printf '%s\n' "${token%/*}"
    fi
}

# etanhey/layers -> <brew repository>/Library/Taps/etanhey/homebrew-layers
bcs_tap_repo_path() {
    local tap="$1"
    local user="${tap%%/*}"
    local repo="${tap##*/}"
    local brew_repository
    brew_repository="$(bcs_brew --repository)" || return 1
    printf '%s/Library/Taps/%s/homebrew-%s\n' "$brew_repository" "$user" "$repo"
}

bcs_caskroom_path() {
    local name="$1"
    local prefix
    prefix="$(bcs_brew --prefix)" || return 1
    printf '%s/Caskroom/%s\n' "$prefix" "$name"
}

# --- version readers --------------------------------------------------------

bcs_app_bundle_version() {
    if [[ -n "${BREW_CASK_SYNC_TEST_APP_VERSION+x}" ]]; then
        printf '%s\n' "$BREW_CASK_SYNC_TEST_APP_VERSION"
        return 0
    fi
    local app_path="$1"
    local info_plist="$app_path/Contents/Info.plist"
    [[ -f "$info_plist" ]] || return 0
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist" 2>/dev/null || true
}

bcs_cask_registered_version() {
    if [[ -n "${BREW_CASK_SYNC_TEST_CASK_VERSION+x}" ]]; then
        printf '%s\n' "$BREW_CASK_SYNC_TEST_CASK_VERSION"
        return 0
    fi
    local name="$1"
    bcs_brew list --versions --cask "$name" 2>/dev/null | awk 'NR==1 {print $2}'
}

bcs_formula_version() {
    if [[ -n "${BREW_CASK_SYNC_TEST_FORMULA_VERSION+x}" ]]; then
        printf '%s\n' "$BREW_CASK_SYNC_TEST_FORMULA_VERSION"
        return 0
    fi
    local name="$1"
    bcs_brew list --versions "$name" 2>/dev/null | awk 'NR==1 {print $2}'
}

# The version the tap is currently OFFERING, read straight from the tapped .rb.
# `brew info` would answer from the API cache; the .rb is the file brew installs.
bcs_tap_offered_version() {
    if [[ -n "${BREW_CASK_SYNC_TEST_OFFERED_VERSION+x}" ]]; then
        printf '%s\n' "$BREW_CASK_SYNC_TEST_OFFERED_VERSION"
        return 0
    fi
    local token="$1"
    local name tap tap_repo cask_file
    name="$(bcs_cask_name "$token")"
    tap="$(bcs_cask_tap "$token")"
    [[ -n "$tap" ]] || return 0
    tap_repo="$(bcs_tap_repo_path "$tap")" || return 0
    cask_file="$tap_repo/Casks/$name.rb"
    [[ -f "$cask_file" ]] || return 0
    awk '/^[[:space:]]*version "/ { gsub(/"/, "", $2); print $2; exit }' "$cask_file"
}

# --- tap freshness ----------------------------------------------------------

# `brew update` did NOT refresh etanhey/layers on 2026-08-19: it sat 3 commits
# behind, still serving the destructive `delete:` cask. The tap has no upstream
# tracking branch, so a bare `git pull` fails — name the remote and branch.
bcs_tap_update() {
    local tap="$1"
    local branch="${2:-main}"
    local tap_repo

    [[ -n "$tap" ]] || return 0

    if ! tap_repo="$(bcs_tap_repo_path "$tap")"; then
        bcs_err "could not resolve the Homebrew repository for tap $tap"
        return 1
    fi

    if [[ ! -d "$tap_repo/.git" ]]; then
        bcs_log "tap $tap is not present; tapping it"
        bcs_brew_run tap "$tap"
        return 0
    fi

    bcs_log "refreshing tap $tap ($tap_repo)"
    bcs_run git -C "$tap_repo" pull --ff-only origin "$branch"
}

# --- drift detection --------------------------------------------------------

# Prints exactly one of:
#   managed                  brew's ledger and the installed bundle agree
#   version-drift            both present, versions disagree
#   unmanaged                app on disk, brew has no registration
#   registered-without-app   brew has a registration, no app on disk
#   absent                   neither
bcs_drift_state() {
    local token="$1"
    local app_path="$2"
    local name app_version cask_version

    name="$(bcs_cask_name "$token")"
    app_version="$(bcs_app_bundle_version "$app_path")"
    cask_version="$(bcs_cask_registered_version "$name")"

    if [[ -z "$app_version" && -z "$cask_version" ]]; then
        printf 'absent\n'
    elif [[ -z "$app_version" ]]; then
        printf 'registered-without-app\n'
    elif [[ -z "$cask_version" ]]; then
        printf 'unmanaged\n'
    elif [[ "$app_version" != "$cask_version" ]]; then
        printf 'version-drift\n'
    else
        printf 'managed\n'
    fi
}

# --- root-safety ------------------------------------------------------------

# True when the OLD saved cask brew would run on uninstall shells out to root.
# `delete:` always becomes `sudo rm`; `sudo: true` says so outright.
bcs_saved_uninstall_needs_root() {
    case "${BREW_CASK_SYNC_TEST_SAVED_UNINSTALL_NEEDS_ROOT:-}" in
        1) return 0 ;;
        0) return 1 ;;
    esac

    local name="$1"
    local caskroom metadata
    caskroom="$(bcs_caskroom_path "$name")" || return 1
    metadata="$caskroom/.metadata"
    [[ -d "$metadata" ]] || return 1

    grep -R -q -E '(^|[[:space:]])(delete:|sudo:[[:space:]]*true)' "$metadata" 2>/dev/null
}

# Guard BEFORE anything destructive: if clearing the registration would need
# root, stop and say so rather than half-uninstalling and then failing.
bcs_caskroom_is_clearable() {
    local name="$1"
    local caskroom parent
    caskroom="$(bcs_caskroom_path "$name")" || return 1
    [[ -e "$caskroom" ]] || return 0
    parent="$(dirname "$caskroom")"
    [[ -w "$parent" && -w "$caskroom" ]]
}

# --- repair -----------------------------------------------------------------

# Move (never delete) the stale registration aside, then adopt the app in place.
bcs_reregister_cask() {
    local token="$1"
    local backup_root="$2"
    local name caskroom stamp destination

    name="$(bcs_cask_name "$token")"
    caskroom="$(bcs_caskroom_path "$name")" || return 1

    if ! bcs_caskroom_is_clearable "$name"; then
        bcs_err "$caskroom is not user-writable; clearing it would need sudo and there is no TTY here."
        bcs_err "Nothing has been changed. Fix the ownership of that directory, then re-run."
        return 1
    fi

    if [[ -e "$caskroom" ]]; then
        stamp="$(date +%Y%m%d-%H%M%S)"
        destination="$backup_root/$name-caskroom-$stamp"
        bcs_log "clearing the stale $name registration (kept at $destination)"
        bcs_run mkdir -p "$backup_root"
        bcs_run mv "$caskroom" "$destination"
    fi

    bcs_log "adopting the installed app with brew (install --cask --force)"
    bcs_brew_run install --cask --force "$token"
}

# One idempotent entry point, correct from ANY starting state.
#   bcs_sync_cask <token> <app path> <backup root> [tap branch]
bcs_sync_cask() {
    local token="$1"
    local app_path="$2"
    local backup_root="$3"
    local branch="${4:-main}"
    local name tap state app_version offered

    bcs_require_brew || return 1

    name="$(bcs_cask_name "$token")"
    tap="$(bcs_cask_tap "$token")"

    bcs_tap_update "$tap" "$branch" || return 1

    state="$(bcs_drift_state "$token" "$app_path")"
    app_version="$(bcs_app_bundle_version "$app_path")"
    offered="$(bcs_tap_offered_version "$token")"
    bcs_log "state: $state (app='${app_version:-none}' cask='$(bcs_cask_registered_version "$name")' offered='${offered:-unknown}')"

    case "$state" in
        absent)
            bcs_brew_run install --cask "$token"
            ;;
        unmanaged|version-drift|registered-without-app)
            bcs_log "drift detected ($state): NOT upgrading — an upgrade would run the old version's uninstall recipe."
            bcs_reregister_cask "$token" "$backup_root" || return 1
            ;;
        managed)
            if [[ -n "$offered" && "$offered" != "$app_version" ]]; then
                if bcs_saved_uninstall_needs_root "$name"; then
                    bcs_log "the registered $app_version cask uninstalls with a root-only recipe; re-registering instead of upgrading."
                    bcs_reregister_cask "$token" "$backup_root" || return 1
                else
                    bcs_brew_run upgrade --cask "$token"
                fi
            else
                bcs_log "$name is already canonical at ${app_version:-unknown}; nothing to do."
            fi
            ;;
        *)
            bcs_err "unrecognised drift state: $state"
            return 1
            ;;
    esac

    # The tap is the source of truth for what canonical means. Assert we landed
    # there rather than trusting the command's exit status.
    if [[ -n "$offered" ]] && ! bcs_commands_are_simulated; then
        local final_app final_cask
        final_app="$(bcs_app_bundle_version "$app_path")"
        final_cask="$(bcs_cask_registered_version "$name")"
        if [[ "$final_app" != "$offered" || "$final_cask" != "$offered" ]]; then
            bcs_err "$name did not reach the offered version $offered (app='${final_app:-none}', cask='${final_cask:-none}')."
            return 1
        fi
    fi

    bcs_log "$name is registered and installed at ${offered:-$app_version}."
}
