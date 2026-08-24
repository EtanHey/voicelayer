#!/usr/bin/env bash
# Update the installed VoiceLayer package, rebuild the canonical VoiceBar.app,
# and perform one VoiceBar-owned daemon stack restart after postflight repairs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/brew-cask-sync.sh
. "$SCRIPT_DIR/lib/brew-cask-sync.sh"
HOME_DIR="${HOME:?HOME is required}"
VOICELAYER_HOME="$HOME_DIR/.voicelayer"
STATE_HOME="$HOME_DIR/.local/state/voicelayer"
VENV_DIR="${VOICELAYER_UPDATE_VENV_DIR:-$VOICELAYER_HOME/venv}"
MODEL_DIR="${VOICELAYER_UPDATE_MODEL_DIR:-$VOICELAYER_HOME/models/qwen3-tts-4bit}"
QWEN3_MODEL_REPO="${VOICELAYER_UPDATE_QWEN3_MODEL_REPO:-mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit}"
MLX_AUDIO_VERSION_SPEC="${VOICELAYER_UPDATE_MLX_AUDIO_VERSION_SPEC:-mlx-audio>=0.4,<0.5}"

DRY_RUN=0
DRY_RUN_COMMANDS="${VOICELAYER_UPDATE_DRY_RUN_COMMANDS:-0}"
DATA_SOURCE="${VOICELAYER_UPDATE_DATA_SOURCE:-}"
DATA_MODE="${VOICELAYER_UPDATE_DATA_MODE:-skip}"
RSYNC_BIN="${VOICELAYER_UPDATE_RSYNC_BIN:-rsync}"
PACKAGE_NAME="${VOICELAYER_UPDATE_PACKAGE_NAME:-voicelayer-mcp}"
VOICEBAR_STABLE_CODESIGN_IDENTITY="Developer ID Application: Etan Heyman (PPN23G925Y)"
# The Homebrew cask's fully-qualified name -- a public tap coordinate, not a
# credential. It was called *_CASK_TOKEN after Homebrew's own "cask token"
# vocabulary, which made secret scanners (DeepSource SCT-1000) read it as a
# hardcoded secret. The default literal is kept on its own line, away from any
# deprecated-name reference, so no scanner reads the pair as a credential.
VOICEBAR_CASK_NAME="etanhey/layers/voicebar"
if [[ -n "${VOICELAYER_UPDATE_VOICEBAR_CASK_NAME:-}" ]]; then
    VOICEBAR_CASK_NAME="$VOICELAYER_UPDATE_VOICEBAR_CASK_NAME"
elif [[ -n "${VOICELAYER_UPDATE_VOICEBAR_CASK_TOKEN:-}" ]]; then
    # Deprecated spelling of the override above. Remove after 2026-09-24.
    VOICEBAR_CASK_NAME="$VOICELAYER_UPDATE_VOICEBAR_CASK_TOKEN"
fi
VOICEBAR_CANONICAL_APP="/Applications/VoiceBar.app"
VOICEBAR_BUNDLE_ID="com.voicelayer.voicebar"
VOICEBAR_REQUIRED_TEAM_ID="PPN23G925Y"
BUILD_APP_ARGS=()
NO_STOP=0
NO_RELAUNCH=0
VOICEBAR_HEALTH_MAX_ATTEMPTS=10
VOICEBAR_HEALTH_RETRY_DELAY_SECONDS=1
VERIFY_FAILURES=0
VOICEBAR_FORMULA_NAME="${VOICELAYER_UPDATE_VOICEBAR_FORMULA_NAME:-voicelayer}"
VOICEBAR_CASK_TAP_BRANCH="${VOICELAYER_UPDATE_CASK_TAP_BRANCH:-main}"
CASK_BACKUP_ROOT="${VOICELAYER_UPDATE_CASK_BACKUP_ROOT:-$HOME_DIR/Library/Application Support/VoiceBar/Backups}"
MCP_SOCKET_PATH="${VOICELAYER_MCP_SOCKET_PATH:-${QA_VOICE_MCP_SOCKET_PATH:-/tmp/voicelayer-mcp.sock}}"
VOICEBAR_SOCKET_PATH="${VOICELAYER_SOCKET_PATH:-${QA_VOICE_SOCKET_PATH:-/tmp/voicelayer.sock}}"

# brew-cask-sync asserts post-conditions; it must not do that when run_cmd is
# only printing.
bcs_caller_simulates_commands() {
    [[ "$DRY_RUN" -eq 1 || "$DRY_RUN_COMMANDS" = "1" ]]
}

usage() {
    cat <<'EOF'
Usage: voicelayer update [--dry-run] [--data-mode skip|direct|brain-drive] [--data-source SOURCE_HOME] [--no-stop] [--no-relaunch]

Runs on the target Mac. SOURCE_HOME is optional personal runtime data, either:
  direct:      main-mac.local:/Users/etanheyman
  brain-drive: /Volumes/BrainDrive/VoiceLayerBackup/etanheyman

Environment overrides:
  VOICELAYER_UPDATE_DATA_SOURCE
  VOICELAYER_UPDATE_DATA_MODE
  VOICELAYER_UPDATE_QWEN3_MODEL_REPO
  VOICELAYER_UPDATE_VOICEBAR_CASK_NAME   Homebrew cask name (default etanhey/layers/voicebar)
                                         old name VOICELAYER_UPDATE_VOICEBAR_CASK_TOKEN is
                                         deprecated and removed after 2026-09-24
  VOICELAYER_UPDATE_DRY_RUN_COMMANDS=1  print and skip commands even without --dry-run
EOF
}

log() {
    printf '%s\n' "$*"
}

err() {
    printf 'ERROR: %s\n' "$*" >&2
}

quote_arg() {
    printf '%q' "$1"
}

print_command() {
    local first=1
    local arg
    for arg in "$@"; do
        if [[ "$first" -eq 0 ]]; then
            printf ' '
        fi
        quote_arg "$arg"
        first=0
    done
    printf '\n'
}

run_cmd() {
    log "+ $(print_command "$@")"
    if [[ "$DRY_RUN" -eq 0 && "$DRY_RUN_COMMANDS" != "1" ]]; then
        "$@"
    fi
}

normalize_source_home() {
    local source_home="$1"
    while [[ "$source_home" == */ ]]; do
        source_home="${source_home%/}"
    done
    if [[ -z "$source_home" ]]; then
        err "source home must not be empty"
        exit 2
    fi
    if [[ "$source_home" == *".."* ]]; then
        err "source home must not contain '..': $source_home"
        exit 2
    fi
    printf '%s\n' "$source_home"
}

source_path() {
    local rel_path="$1"
    local source_home
    source_home="$(normalize_source_home "$DATA_SOURCE")"
    printf '%s/%s' "$source_home" "$rel_path"
}

rsync_item() {
    local rel_path="$1"
    local dest_path="$2"
    local src_path
    src_path="$(source_path "$rel_path")"
    run_cmd mkdir -p "$(dirname "$dest_path")"
    run_cmd "$RSYNC_BIN" -a --delete "$src_path" "$dest_path"
}

ensure_command() {
    local name="$1"
    if ! command -v "$name" >/dev/null 2>&1; then
        err "$name is required"
        exit 1
    fi
}

parse_args() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --data-source)
                if [[ "$#" -lt 2 ]]; then
                    err "--data-source requires a value"
                    exit 2
                fi
                DATA_SOURCE="$2"
                shift 2
                ;;
            --data-mode)
                if [[ "$#" -lt 2 ]]; then
                    err "--data-mode requires direct or brain-drive"
                    exit 2
                fi
                DATA_MODE="$2"
                shift 2
                ;;
            --no-stop)
                NO_STOP=1
                BUILD_APP_ARGS+=("--no-stop")
                shift
                ;;
            --no-relaunch)
                NO_RELAUNCH=1
                BUILD_APP_ARGS+=("--no-relaunch")
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                err "unknown argument: $1"
                usage >&2
                exit 2
                ;;
        esac
    done

    # A local build must never relaunch before model/data work and postflight
    # repairs complete. Preserve NO_RELAUNCH as user intent while adding the
    # internal build-only opt-out exactly once.
    if [[ "$NO_RELAUNCH" -eq 0 ]]; then
        BUILD_APP_ARGS+=("--no-relaunch")
    fi
}

validate_args() {
    case "$DATA_MODE" in
        skip|direct|brain-drive) ;;
        *)
            err "--data-mode must be skip, direct, or brain-drive"
            exit 2
            ;;
    esac

    if [[ "$DATA_MODE" != "skip" && -z "$DATA_SOURCE" ]]; then
        err "--data-source is required when --data-mode is direct or brain-drive"
        exit 2
    fi
}

detect_install_type() {
    if [[ -n "${VOICELAYER_UPDATE_TEST_INSTALL_TYPE:-}" ]]; then
        printf '%s\n' "$VOICELAYER_UPDATE_TEST_INSTALL_TYPE"
        return
    fi
    local git_root
    local package_root_real
    local git_root_real
    if git_root="$(git -C "$PACKAGE_ROOT" rev-parse --show-toplevel 2>/dev/null)"; then
        package_root_real="$(cd "$PACKAGE_ROOT" && pwd -P)"
        git_root_real="$(cd "$git_root" && pwd -P)"
    else
        git_root_real=""
        package_root_real=""
    fi
    if [[ -n "$git_root_real" && "$git_root_real" == "$package_root_real" ]]; then
        printf 'git-checkout\n'
    else
        printf 'global-package\n'
    fi
}

package_update_label() {
    case "$(detect_install_type)" in
        git-checkout)
            printf 'git pull --ff-only && bun install\n'
            ;;
        *)
            if command -v bun >/dev/null 2>&1; then
                printf 'bun update -g %s\n' "$PACKAGE_NAME"
            else
                printf 'npm install -g %s\n' "$PACKAGE_NAME"
            fi
            ;;
    esac
}

voicebar_cask_installed() {
    case "${VOICELAYER_UPDATE_TEST_BREW_CASK_INSTALLED:-}" in
        1) return 0 ;;
        0) return 1 ;;
    esac

    bcs_brew_bin >/dev/null 2>&1 && [[ -n "$(bcs_cask_registered_version "$(bcs_cask_name "$VOICEBAR_CASK_NAME")")" ]]
}

voicebar_app_update_mode() {
    if voicebar_cask_installed; then
        printf 'cask-sync\n'
        return
    fi

    case "$(detect_install_type)" in
        git-checkout)
            printf 'local-build\n'
            ;;
        *)
            printf 'cask-sync\n'
            ;;
    esac
}

voicebar_app_update_label() {
    case "$(voicebar_app_update_mode)" in
        cask-sync)
            printf 'drift-proof brew cask sync of %s\n' "$VOICEBAR_CASK_NAME"
            ;;
        *)
            print_command env "VOICEBAR_CODESIGN_IDENTITY=$VOICEBAR_STABLE_CODESIGN_IDENTITY" bash flow-bar/build-app.sh "${BUILD_APP_ARGS[@]+"${BUILD_APP_ARGS[@]}"}"
            ;;
    esac
}

voicebar_cask_repair_needed() {
    case "${VOICELAYER_UPDATE_TEST_CASK_REPAIR_NEEDED:-}" in
        1) return 0 ;;
        0) return 1 ;;
    esac

    # Command-stubbed tests must not depend on the developer machine's resident
    # application. A test that exercises this branch opts in above.
    if [[ "$DRY_RUN_COMMANDS" = "1" ]]; then
        return 1
    fi

    local info_plist="$VOICEBAR_CANONICAL_APP/Contents/Info.plist"
    local bundle_id
    local signature
    local team_id
    local authority

    [[ -f "$info_plist" ]] || return 0
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist" 2>/dev/null || true)"
    [[ "$bundle_id" = "$VOICEBAR_BUNDLE_ID" ]] || return 0
    codesign --verify --deep --strict "$VOICEBAR_CANONICAL_APP" >/dev/null 2>&1 || return 0

    signature="$(codesign -dvvv "$VOICEBAR_CANONICAL_APP" 2>&1 || true)"
    team_id="$(printf '%s\n' "$signature" | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
    authority="$(printf '%s\n' "$signature" | awk -F= '/^Authority=/{print $2; exit}')"
    [[ "$team_id" = "$VOICEBAR_REQUIRED_TEAM_ID" ]] || return 0
    [[ "$authority" = "Developer ID Application"* ]] || return 0

    return 1
}

print_plan() {
    local install_type
    local app_update
    install_type="$(detect_install_type)"
    app_update="$(voicebar_app_update_label)"
    log "VoiceLayer M1 update plan"
    log "DRY RUN: $([[ "$DRY_RUN" -eq 1 ]] && printf yes || printf no)"
    log "INSTALL TYPE: $install_type"
    log "PACKAGE ROOT: $PACKAGE_ROOT"
    log "PACKAGE UPDATE: $(package_update_label)"
    log "VOICEBAR APP UPDATE: $app_update"
    if [[ "$DATA_MODE" != "skip" ]]; then
        log "DATA MODE: $DATA_MODE"
        log "DATA SOURCE: $DATA_SOURCE"
    else
        log "DATA MODE: skip"
        log "Personal data sync: skipped"
    fi
    log "Qwen3 model: $MODEL_DIR ($QWEN3_MODEL_REPO)"
    log ""
    log "Steps:"
    log "  1. update package: $(package_update_label)"
    log "  2. install package dependencies when running from a git checkout"
    case "$(voicebar_app_update_mode)" in
        local-build)
            log "  3. + $app_update (postflight performs the single requested VoiceBar relaunch)"
            ;;
        *)
            log "  3. + $app_update (refresh the tap, detect drift, adopt with --force instead of a destructive upgrade)"
            ;;
    esac
    log "  4. create/update $VENV_DIR and pull Qwen3 model if missing"
    if [[ "$DATA_MODE" != "skip" ]]; then
        log "  5. rsync personal data:"
        log "     $(source_path ".voicelayer/voices/") -> $VOICELAYER_HOME/voices/"
        log "     $(source_path ".voicelayer/voices.json") -> $VOICELAYER_HOME/voices.json"
        log "     $(source_path ".voicelayer/pronunciation.yaml") -> $VOICELAYER_HOME/pronunciation.yaml"
        log "     $(source_path ".voicelayer/daemon.secret") -> $VOICELAYER_HOME/daemon.secret"
        log "     $(source_path ".local/state/voicelayer/stt-vocabulary.json") -> $STATE_HOME/stt-vocabulary.json"
        log "  6. dedupe VoiceBar, restore F5 remap + autostart, and verify hotkey health"
        log "  7. verify app/cask/formula/process/launchd/sockets and print a green summary"
    else
        log "  5. dedupe VoiceBar, restore F5 remap + autostart, and verify hotkey health"
        log "  6. verify app/cask/formula/process/launchd/sockets and print a green summary"
    fi
    log ""
}

warn_if_dirty() {
    local status_output
    status_output="$(git -C "$PACKAGE_ROOT" status --porcelain)"
    if [[ -n "$status_output" ]]; then
        log "WARNING: git worktree has local changes; git pull --ff-only may fail."
        log "$status_output"
    fi
}

install_qwen3_model() {
    if [[ -d "$MODEL_DIR" && -n "$(find "$MODEL_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
        log "Qwen3 model already present: $MODEL_DIR"
        return
    fi

    run_cmd mkdir -p "$VOICELAYER_HOME/models"
    if [[ ! -x "$VENV_DIR/bin/python" ]]; then
        run_cmd python3 -m venv "$VENV_DIR"
    fi
    run_cmd "$VENV_DIR/bin/python" -m pip install --upgrade pip
    run_cmd "$VENV_DIR/bin/python" -m pip install "$MLX_AUDIO_VERSION_SPEC" huggingface_hub uvicorn fastapi pydantic soundfile numpy
    run_cmd mkdir -p "$MODEL_DIR"
    run_cmd "$VENV_DIR/bin/huggingface-cli" download "$QWEN3_MODEL_REPO" --local-dir "$MODEL_DIR"
}

sync_personal_data() {
    if [[ "$DATA_MODE" = "skip" ]]; then
        return
    fi
    run_cmd mkdir -p "$VOICELAYER_HOME" "$STATE_HOME"
    rsync_item ".voicelayer/voices/" "$VOICELAYER_HOME/voices/"
    rsync_item ".voicelayer/voices.json" "$VOICELAYER_HOME/voices.json"
    rsync_item ".voicelayer/pronunciation.yaml" "$VOICELAYER_HOME/pronunciation.yaml"
    rsync_item ".voicelayer/daemon.secret" "$VOICELAYER_HOME/daemon.secret"
    rsync_item ".local/state/voicelayer/stt-vocabulary.json" "$STATE_HOME/stt-vocabulary.json"
    run_cmd chmod 700 "$VOICELAYER_HOME"
    if [[ -f "$VOICELAYER_HOME/daemon.secret" || "$DRY_RUN" -eq 1 ]]; then
        run_cmd chmod 600 "$VOICELAYER_HOME/daemon.secret"
    fi
}

update_package() {
    case "$(detect_install_type)" in
        git-checkout)
            ensure_command git
            ensure_command bun
            warn_if_dirty
            run_cmd git -C "$PACKAGE_ROOT" pull --ff-only
            run_cmd bun install --cwd "$PACKAGE_ROOT"
            ;;
        *)
            if command -v bun >/dev/null 2>&1; then
                run_cmd bun update -g "$PACKAGE_NAME"
            else
                ensure_command npm
                run_cmd npm install -g "$PACKAGE_NAME"
            fi
            ;;
    esac
}

update_voicebar_app() {
    case "$(voicebar_app_update_mode)" in
        cask-sync)
            bcs_sync_cask \
                "$VOICEBAR_CASK_NAME" \
                "$VOICEBAR_CANONICAL_APP" \
                "$CASK_BACKUP_ROOT" \
                "$VOICEBAR_CASK_TAP_BRANCH"
            if voicebar_cask_repair_needed; then
                log "Resident VoiceBar failed canonical signature checks; reinstalling the cask."
                bcs_brew_run reinstall --cask "$VOICEBAR_CASK_NAME"
            fi
            ;;
        *)
            run_cmd env "VOICEBAR_CODESIGN_IDENTITY=$VOICEBAR_STABLE_CODESIGN_IDENTITY" bash "$PACKAGE_ROOT/flow-bar/build-app.sh" "${BUILD_APP_ARGS[@]+"${BUILD_APP_ARGS[@]}"}"
            ;;
    esac
}

verify_voicebar_hotkey_health() {
    local health_args=("$@")
    local health_script="$PACKAGE_ROOT/scripts/verify-voicebar-hotkey-health.sh"
    local attempt=1

    while [[ "$attempt" -le "$VOICEBAR_HEALTH_MAX_ATTEMPTS" ]]; do
        if run_cmd bash "$health_script" "${health_args[@]+"${health_args[@]}"}"; then
            return 0
        fi
        if [[ "$attempt" -lt "$VOICEBAR_HEALTH_MAX_ATTEMPTS" ]]; then
            log "VoiceBar hotkey health is not ready (attempt $attempt/$VOICEBAR_HEALTH_MAX_ATTEMPTS); retrying."
            run_cmd sleep "$VOICEBAR_HEALTH_RETRY_DELAY_SECONDS"
        fi
        attempt=$((attempt + 1))
    done

    err "VoiceBar hotkey health did not become ready after $VOICEBAR_HEALTH_MAX_ATTEMPTS attempts"
    return 1
}

repair_and_verify_voicebar_hotkey_path() {
    local dedupe_args=(--apply)
    local health_args=()

    if [[ "$NO_STOP" -eq 1 ]]; then
        dedupe_args+=(--no-stop)
    fi
    if [[ "$NO_STOP" -eq 1 || "$NO_RELAUNCH" -eq 1 ]]; then
        health_args+=(--allow-stopped)
    fi
    dedupe_args+=(--no-relaunch)

    run_cmd bash "$PACKAGE_ROOT/scripts/voicelayer-dedupe-voicebar.sh" "${dedupe_args[@]}"
    run_cmd bash "$PACKAGE_ROOT/scripts/install-voicebar-f5-hidutil.sh"
    if [[ "$NO_STOP" -eq 0 && "$NO_RELAUNCH" -eq 0 ]]; then
        run_cmd bash "$PACKAGE_ROOT/scripts/install-voicebar-autostart.sh" --reload
    elif [[ "$NO_STOP" -eq 1 ]]; then
        run_cmd bash "$PACKAGE_ROOT/scripts/install-voicebar-autostart.sh" --preserve-load-state
    else
        run_cmd bash "$PACKAGE_ROOT/scripts/install-voicebar-autostart.sh" --no-start
    fi

    verify_voicebar_hotkey_health "${health_args[@]+"${health_args[@]}"}"
}

check_row() {
    # check_row <label> <ok:0|1> <detail>
    local label="$1"
    local ok="$2"
    local detail="$3"
    if [[ "$ok" -eq 0 ]]; then
        log "  OK    $label: $detail"
    else
        log "  FAIL  $label: $detail"
        VERIFY_FAILURES=$((VERIFY_FAILURES + 1))
    fi
}

launchd_service_loaded() {
    launchctl print "gui/$(id -u)/$1" >/dev/null 2>&1
}

verify_voicebar_stack() {
    local cask_name app_version cask_version formula_version offered
    local expect_running=1
    VERIFY_FAILURES=0

    if [[ "$NO_STOP" -eq 1 || "$NO_RELAUNCH" -eq 1 ]]; then
        expect_running=0
    fi

    cask_name="$(bcs_cask_name "$VOICEBAR_CASK_NAME")"
    app_version="$(bcs_app_bundle_version "$VOICEBAR_CANONICAL_APP")"
    cask_version="$(bcs_cask_registered_version "$cask_name")"
    formula_version="$(bcs_formula_version "$VOICEBAR_FORMULA_NAME")"
    offered="$(bcs_tap_offered_version "$VOICEBAR_CASK_NAME")"

    log ""
    log "VoiceLayer sync summary"

    check_row "tap offer" "$([[ -n "$offered" ]] && printf 0 || printf 1)" \
        "${offered:-could not read the tapped cask}"
    check_row "app bundle" "$([[ -n "$app_version" && ( -z "$offered" || "$app_version" = "$offered" ) ]] && printf 0 || printf 1)" \
        "${app_version:-not installed} ($VOICEBAR_CANONICAL_APP)"
    check_row "cask ledger" "$([[ -n "$cask_version" && ( -z "$offered" || "$cask_version" = "$offered" ) ]] && printf 0 || printf 1)" \
        "${cask_version:-not registered with brew}"
    check_row "formula" "$([[ -n "$formula_version" && ( -z "$offered" || "$formula_version" = "$offered" ) ]] && printf 0 || printf 1)" \
        "$VOICEBAR_FORMULA_NAME ${formula_version:-not installed}"

    if [[ "$expect_running" -eq 1 ]]; then
        check_row "process" "$(pgrep -f "$VOICEBAR_CANONICAL_APP/Contents/MacOS/" >/dev/null 2>&1 && printf 0 || printf 1)" \
            "VoiceBar running"
        check_row "launchd voicebar" "$(launchd_service_loaded com.voicelayer.voicebar && printf 0 || printf 1)" \
            "com.voicelayer.voicebar"
        check_row "launchd F5 relay" "$(launchd_service_loaded com.voicelayer.f5-to-f18-hidutil && printf 0 || printf 1)" \
            "com.voicelayer.f5-to-f18-hidutil"
        check_row "voicebar socket" "$([[ -S "$VOICEBAR_SOCKET_PATH" ]] && printf 0 || printf 1)" \
            "$VOICEBAR_SOCKET_PATH"
        check_row "mcp socket" "$([[ -S "$MCP_SOCKET_PATH" ]] && printf 0 || printf 1)" \
            "$MCP_SOCKET_PATH"
    else
        log "  SKIP  runtime checks: --no-stop/--no-relaunch asked for VoiceBar to stay down"
    fi

    if [[ "$VERIFY_FAILURES" -ne 0 ]]; then
        err "VoiceLayer is NOT canonical on this Mac: $VERIFY_FAILURES check(s) failed above."
        return 1
    fi

    log "GREEN: this Mac is canonical at ${offered:-$app_version}."
}

main() {
    parse_args "$@"
    validate_args
    print_plan

    if [[ "$DRY_RUN" -eq 1 ]]; then
        return 0
    fi

    case "$(detect_install_type)" in
        git-checkout)
            ensure_command bun
            ;;
        *)
            if ! command -v bun >/dev/null 2>&1; then
                ensure_command npm
            fi
            ;;
    esac
    ensure_command python3
    if [[ "$DATA_MODE" != "skip" ]]; then
        ensure_command "$RSYNC_BIN"
    fi
    case "$(voicebar_app_update_mode)" in
        cask-sync)
            if [[ "$DRY_RUN_COMMANDS" != "1" ]]; then
                bcs_require_brew || exit 1
            fi
            ;;
    esac

    update_package
    update_voicebar_app
    install_qwen3_model
    sync_personal_data
    repair_and_verify_voicebar_hotkey_path
    if [[ "$DRY_RUN_COMMANDS" != "1" ]]; then
        verify_voicebar_stack
    fi
    log "VoiceLayer update complete."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
