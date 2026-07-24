#!/usr/bin/env bash
# Update the installed VoiceLayer package, rebuild the canonical VoiceBar.app,
# and let build-app complete the local VoiceBar-owned daemon stack restart.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
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
VOICEBAR_CASK_TOKEN="${VOICELAYER_UPDATE_VOICEBAR_CASK_TOKEN:-etanhey/layers/voicebar}"
BUILD_APP_ARGS=()
NO_STOP=0
NO_RELAUNCH=0

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

    command -v brew >/dev/null 2>&1 && brew list --cask voicebar >/dev/null 2>&1
}

voicebar_app_update_mode() {
    if voicebar_cask_installed; then
        printf 'cask-upgrade\n'
        return
    fi

    case "$(detect_install_type)" in
        git-checkout)
            printf 'local-build\n'
            ;;
        *)
            printf 'cask-install\n'
            ;;
    esac
}

voicebar_app_update_label() {
    case "$(voicebar_app_update_mode)" in
        cask-upgrade)
            printf 'brew upgrade --cask %s\n' "$VOICEBAR_CASK_TOKEN"
            ;;
        cask-install)
            printf 'brew install --cask %s\n' "$VOICEBAR_CASK_TOKEN"
            ;;
        *)
            print_command env "VOICEBAR_CODESIGN_IDENTITY=$VOICEBAR_STABLE_CODESIGN_IDENTITY" bash flow-bar/build-app.sh "${BUILD_APP_ARGS[@]+"${BUILD_APP_ARGS[@]}"}"
            ;;
    esac
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
            log "  3. + $app_update (build-app.sh relaunches VoiceBar unless --no-relaunch is set)"
            ;;
        *)
            log "  3. + $app_update (Homebrew installs the notarized VoiceBar cask artifact)"
            ;;
    esac
    log "  4. dedupe VoiceBar, restore F5 remap + autostart, and verify hotkey health"
    log "  5. create/update $VENV_DIR and pull Qwen3 model if missing"
    if [[ "$DATA_MODE" != "skip" ]]; then
        log "  6. rsync personal data:"
        log "     $(source_path ".voicelayer/voices/") -> $VOICELAYER_HOME/voices/"
        log "     $(source_path ".voicelayer/voices.json") -> $VOICELAYER_HOME/voices.json"
        log "     $(source_path ".voicelayer/pronunciation.yaml") -> $VOICELAYER_HOME/pronunciation.yaml"
        log "     $(source_path ".voicelayer/daemon.secret") -> $VOICELAYER_HOME/daemon.secret"
        log "     $(source_path ".local/state/voicelayer/stt-vocabulary.json") -> $STATE_HOME/stt-vocabulary.json"
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
        cask-upgrade)
            run_cmd brew upgrade --cask "$VOICEBAR_CASK_TOKEN"
            ;;
        cask-install)
            run_cmd brew install --cask "$VOICEBAR_CASK_TOKEN"
            ;;
        *)
            run_cmd env "VOICEBAR_CODESIGN_IDENTITY=$VOICEBAR_STABLE_CODESIGN_IDENTITY" bash "$PACKAGE_ROOT/flow-bar/build-app.sh" "${BUILD_APP_ARGS[@]+"${BUILD_APP_ARGS[@]}"}"
            ;;
    esac
}

repair_and_verify_voicebar_hotkey_path() {
    local dedupe_args=(--apply)
    local health_args=()

    if [[ "$NO_STOP" -eq 1 || "$NO_RELAUNCH" -eq 1 ]]; then
        dedupe_args+=(--no-stop)
        health_args+=(--allow-stopped)
    fi
    dedupe_args+=(--no-relaunch)

    run_cmd bash "$PACKAGE_ROOT/scripts/voicelayer-dedupe-voicebar.sh" "${dedupe_args[@]}"
    run_cmd bash "$PACKAGE_ROOT/scripts/install-voicebar-f5-hidutil.sh"
    run_cmd bash "$PACKAGE_ROOT/scripts/install-voicebar-autostart.sh"

    if [[ "$NO_STOP" -eq 0 && "$NO_RELAUNCH" -eq 0 ]]; then
        run_cmd launchctl kickstart -k "gui/$(id -u)/com.voicelayer.voicebar"
    fi

    run_cmd bash "$PACKAGE_ROOT/scripts/verify-voicebar-hotkey-health.sh" "${health_args[@]+"${health_args[@]}"}"
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
        cask-upgrade|cask-install)
            if [[ "$DRY_RUN_COMMANDS" != "1" ]]; then
                ensure_command brew
            fi
            ;;
    esac

    update_package
    update_voicebar_app
    repair_and_verify_voicebar_hotkey_path
    install_qwen3_model
    sync_personal_data
    log "VoiceLayer update complete."
}

main "$@"
