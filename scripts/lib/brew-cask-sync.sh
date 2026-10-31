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
        [[ -x "$BREW_CASK_SYNC_BREW_BIN" ]] || return 1
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
    if bcs_function_exists run_cmd && bcs_function_exists bcs_caller_simulates_commands; then
        bcs_caller_simulates_commands
        return
    fi
    return 1
}

# Mutating brew call, routed through run_cmd so --dry-run prints instead of acts.
#
# AIDEV-NOTE: a missing brew is only fatal when the command would really run.
# Under simulation (--dry-run, or a caller whose run_cmd only prints) there is
# nothing to execute, so print the brew command that WOULD run and carry on --
# otherwise the whole update dies mid-sync on Linux CI or on a Mac before
# Homebrew is installed. bcs_sync_cask short-circuits the same way at its entry,
# but callers make follow-up brew calls of their own (voicelayer-update.sh's
# damaged-app `reinstall`), and those have to survive the same state.
# A real run is still gated: main() calls bcs_require_brew before acting.
bcs_brew_run() {
    bcs_update_gate || return 1
    local brew_bin
    if ! brew_bin="$(bcs_brew_bin)"; then
        if bcs_commands_are_simulated; then
            bcs_run brew "$@"
            return 0
        fi
        bcs_err "Homebrew not found. Expected /opt/homebrew/bin/brew (Apple silicon) or /usr/local/bin/brew."
        return 1
    fi
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
    local version=""
    [[ -f "$info_plist" ]] || return 0

    local plist_buddy="${BREW_CASK_SYNC_PLIST_BUDDY:-/usr/libexec/PlistBuddy}"
    local plutil_bin="${BREW_CASK_SYNC_PLUTIL:-plutil}"

    if [[ -x "$plist_buddy" ]]; then
        version="$("$plist_buddy" -c 'Print :CFBundleShortVersionString' "$info_plist" 2>/dev/null || true)"
    fi
    if [[ -z "$version" ]] && command -v "$plutil_bin" >/dev/null 2>&1; then
        version="$("$plutil_bin" -extract CFBundleShortVersionString raw -o - "$info_plist" 2>/dev/null || true)"
    fi
    # AIDEV-NOTE: last-resort XML parse. A real .app on a Mac always has
    # PlistBuddy, so this branch is only reached where macOS plist tooling does
    # not exist -- Linux CI. Reading the version had to stop being Darwin-only:
    # with PlistBuddy absent every bundle read as "no app", which collapsed all
    # five drift states to registered-without-app/absent and turned the whole
    # brew-cask-sync suite red on ubuntu-latest while it passed locally.
    if [[ -z "$version" ]]; then
        version="$(awk '
            /<key>CFBundleShortVersionString<\/key>/ { want = 1; next }
            want && match($0, /<string>[^<]*<\/string>/) {
                print substr($0, RSTART + 8, RLENGTH - 17); exit
            }
        ' "$info_plist" 2>/dev/null || true)"
    fi

    printf '%s\n' "$version"
}

bcs_cask_registered_version() {
    if [[ -n "${BREW_CASK_SYNC_TEST_CASK_VERSION+x}" ]]; then
        printf '%s\n' "$BREW_CASK_SYNC_TEST_CASK_VERSION"
        return 0
    fi
    local name="$1"
    bcs_brew list --versions --cask "$name" 2>/dev/null | awk 'NR==1 {print $2}'
}

# 0: linked version, or empty for proven absence; 2: Homebrew unavailable;
# 1: query/schema failure or installed formula without one known linked keg.
# Homebrew docs/Querying-Brew.md documents linked_keg; Formula#to_hash emits
# linked_version as a full PkgVersion, independently of retained installed kegs.
bcs_formula_version() {
    if [[ -n "${BREW_CASK_SYNC_TEST_FORMULA_VERSION+x}" ]]; then
        printf '%s\n' "$BREW_CASK_SYNC_TEST_FORMULA_VERSION"
        return 0
    fi
    local name="$1"
    local formula_json inventory rack
    bcs_brew_bin >/dev/null 2>&1 || return 2
    # Unnamed list reads Cellar entries without resolving formulae/taps (Homebrew
    # list.sh and cmd/list.rb). Named info can fail before JSON for an untapped
    # absent formula. A same-basename rack from ANY tap requires the strict query.
    if ! inventory="$(bcs_brew list --formula -1)"; then
        bcs_err "could not query inventory for active formula identity: $name"
        return 1
    fi
    if ! rack="$(printf '%s' "$inventory" | python3 -c '
import re, sys
parts = sys.argv[1].split("/")
names = sys.stdin.read().splitlines()
def valid_name(value):
    # tap_constants.rb: [\w+\-.@]+; Ruby \w is ASCII, with no first-char rule.
    return re.fullmatch(r"[A-Za-z0-9_+\-.@]+", value) is not None
if len(parts) not in (1, 3) or not all(valid_name(part) for part in parts):
    sys.exit("invalid formula token")
if not all(valid_name(name) for name in names) or len(set(names)) != len(names):
    sys.exit("invalid formula rack inventory")
# Unnamed ls omits dot-prefixed racks; only named JSON can prove their absence.
if parts[-1].startswith(".") or parts[-1] in names:
    print(parts[-1])
' "$name")"; then
        bcs_err "could not determine inventory for active formula identity: $name"
        return 1
    fi
    [[ -n "$rack" ]] || return 0
    if ! formula_json="$(bcs_brew info --json=v2 --formula "$name")"; then
        bcs_err "could not query active formula identity for $name"
        return 1
    fi
    if ! printf '%s\n' "$formula_json" | python3 -c '
import json, sys
try:
    formulae = json.load(sys.stdin)["formulae"]
    if not isinstance(formulae, list) or len(formulae) != 1:
        raise ValueError("expected exactly one formula")
    formula = formulae[0]
    identity = "full_name" if "/" in sys.argv[1] else "name"
    if formula[identity] != sys.argv[1]:
        raise ValueError("formula identity mismatch")
    installed = formula["installed"]
    if not isinstance(installed, list) or any(
        not isinstance(keg, dict) or not isinstance(keg.get("version"), str)
        or not keg["version"] for keg in installed
    ):
        raise ValueError("invalid installed keg inventory")
    linked = formula["linked_keg"]
    if not installed and linked is None:
        sys.exit(0)
    if not isinstance(linked, str) or not linked or sum(
        keg["version"] == linked for keg in installed
    ) != 1:
        raise ValueError("installed formula has no unique linked keg")
    print(linked)
except (KeyError, TypeError, ValueError) as error:
    sys.exit(str(error))
' "$name"; then
        bcs_err "could not determine active formula identity for $name"
        return 1
    fi
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
    bcs_update_gate || return 1
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
    bcs_update_gate || return 1
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
    bcs_update_gate || return 1
    local token="$1"
    local app_path="$2"
    local backup_root="$3"
    local branch="${4:-main}"
    local name tap state app_version offered

    # AIDEV-NOTE: under --dry-run-commands nothing is executed, so a missing brew
    # is not a reason to fail -- say what would happen and stop. Detection needs a
    # real brew, so this only short-circuits when there is none AND nothing would
    # run anyway (Linux CI, or a Mac before Homebrew is installed).
    if ! bcs_brew_bin >/dev/null 2>&1 && bcs_commands_are_simulated; then
        bcs_log "no Homebrew on this machine; simulating the drift-proof cask sync of $token."
        return 0
    fi

    bcs_require_brew || return 1

    name="$(bcs_cask_name "$token")"
    tap="$(bcs_cask_tap "$token")"

    bcs_tap_update "$tap" "$branch" || return 1

    state="$(bcs_drift_state "$token" "$app_path")"
    app_version="$(bcs_app_bundle_version "$app_path")"
    offered="$(bcs_tap_offered_version "$token")"

    # AIDEV-NOTE: a tapped token with no readable offer means the tap is missing,
    # half-cloned, or renamed. Without it the post-condition below is skipped and
    # bcs_sync_cask returns 0 having verified nothing -- a silent green on exactly
    # the "tap behind / no tap at all" state this library exists to survive. Stop
    # here, before anything is moved or installed.
    if [[ -n "$tap" && -z "$offered" ]]; then
        bcs_err "tap $tap offers no readable version for $name; refusing to act without a version to verify against."
        bcs_err "Nothing has been changed. Check that $tap is tapped and has Casks/$name.rb, then re-run."
        return 1
    fi

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

# Guard every mutating helper, including direct library consumers. Dry-run is read-only.
bcs_update_gate() {
    bcs_commands_are_simulated && return 0
    if [[ -z "${VOICELAYER_INSTALL_OPERATION:-}" ]]; then
        bcs_err "UNKNOWN: obtain an update operation via voicelayer update before cask/formula mutation"
        return 1
    fi
    local root
    # Formula upgrade can remove the keg that originally sourced this function.
    root="${PACKAGE_ROOT:-}"
    if [[ -z "$root" ]]; then root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || return 1; fi
    if [[ ! -f "$root/scripts/lib/update-gate.sh" ]]; then
        bcs_err "REFUSED UNKNOWN: refreshed package validator unavailable; no further mutation authorized"
        return 1
    fi
    source "$root/scripts/lib/update-gate.sh" || return 1
    vl_update_gate "$root"
}
