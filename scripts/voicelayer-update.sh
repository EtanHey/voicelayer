#!/usr/bin/env bash
# Bring a secondary Mac up to date with the VoiceLayer app, daemon, model, and
# untracked personal runtime data.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOME_DIR="${HOME:?HOME is required}"
VOICELAYER_HOME="$HOME_DIR/.voicelayer"
STATE_HOME="$HOME_DIR/.local/state/voicelayer"
VENV_DIR="${VOICELAYER_UPDATE_VENV_DIR:-$VOICELAYER_HOME/venv}"
MODEL_DIR="${VOICELAYER_UPDATE_MODEL_DIR:-$VOICELAYER_HOME/models/qwen3-tts-4bit}"
QWEN3_MODEL_REPO="${VOICELAYER_UPDATE_QWEN3_MODEL_REPO:-mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit}"

DRY_RUN=0
DATA_SOURCE="${VOICELAYER_UPDATE_DATA_SOURCE:-}"
DATA_MODE="${VOICELAYER_UPDATE_DATA_MODE:-pending}"
RSYNC_BIN="${VOICELAYER_UPDATE_RSYNC_BIN:-rsync}"

usage() {
    cat <<'EOF'
Usage: voicelayer update [--dry-run] [--data-mode direct|brain-drive] --data-source SOURCE_HOME

Runs on the target Mac. SOURCE_HOME is the source user's home directory, either:
  direct:      main-mac.local:/Users/etanheyman
  brain-drive: /Volumes/BrainDrive/VoiceLayerBackup/etanheyman

Environment overrides:
  VOICELAYER_UPDATE_DATA_SOURCE
  VOICELAYER_UPDATE_DATA_MODE
  VOICELAYER_UPDATE_QWEN3_MODEL_REPO
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
    if [[ "$DRY_RUN" -eq 0 ]]; then
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
        pending|direct|brain-drive) ;;
        *)
            err "--data-mode must be direct or brain-drive"
            exit 2
            ;;
    esac

    if [[ "$DRY_RUN" -eq 0 && -z "$DATA_SOURCE" ]]; then
        err "--data-source is required for a real update; Etan still needs to pick direct rsync vs Brain Drive"
        exit 2
    fi
}

print_plan() {
    log "VoiceLayer M1 update plan"
    log "DRY RUN: $([[ "$DRY_RUN" -eq 1 ]] && printf yes || printf no)"
    if [[ -n "$DATA_SOURCE" ]]; then
        log "DATA MODE: $DATA_MODE"
        log "DATA SOURCE: $DATA_SOURCE"
    else
        log "DATA MODE: pending"
        log "DATA SOURCE: pending Etan decision (recommended: Brain Drive backed source)"
    fi
    log "REPO: $REPO_ROOT"
    log "Qwen3 model: $MODEL_DIR ($QWEN3_MODEL_REPO)"
    log ""
    log "Steps:"
    log "  1. git pull --ff-only"
    log "  2. bun install"
    log "  3. bash flow-bar/build-app.sh"
    log "  4. bash launchd/install.sh"
    log "  5. create/update $VENV_DIR and pull Qwen3 model if missing"
    log "  6. rsync personal data:"
    if [[ -n "$DATA_SOURCE" ]]; then
        log "     $(source_path ".voicelayer/voices/") -> $VOICELAYER_HOME/voices/"
        log "     $(source_path ".voicelayer/voices.json") -> $VOICELAYER_HOME/voices.json"
        log "     $(source_path ".voicelayer/pronunciation.yaml") -> $VOICELAYER_HOME/pronunciation.yaml"
        log "     $(source_path ".voicelayer/daemon.secret") -> $VOICELAYER_HOME/daemon.secret"
        log "     $(source_path ".local/state/voicelayer/stt-vocabulary.json") -> $STATE_HOME/stt-vocabulary.json"
    else
        log "     ~/.voicelayer/voices/"
        log "     ~/.voicelayer/voices.json"
        log "     ~/.voicelayer/pronunciation.yaml"
        log "     ~/.voicelayer/daemon.secret"
        log "     ~/.local/state/voicelayer/stt-vocabulary.json"
    fi
    log ""
}

warn_if_dirty() {
    local status_output
    status_output="$(git -C "$REPO_ROOT" status --porcelain)"
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
    run_cmd "$VENV_DIR/bin/python" -m pip install mlx-audio huggingface_hub
    run_cmd mkdir -p "$MODEL_DIR"
    run_cmd "$VENV_DIR/bin/huggingface-cli" download "$QWEN3_MODEL_REPO" --local-dir "$MODEL_DIR"
}

sync_personal_data() {
    if [[ -z "$DATA_SOURCE" ]]; then
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

main() {
    parse_args "$@"
    validate_args
    print_plan

    if [[ "$DRY_RUN" -eq 1 ]]; then
        return 0
    fi

    ensure_command git
    ensure_command bun
    ensure_command python3
    ensure_command "$RSYNC_BIN"

    warn_if_dirty
    run_cmd git -C "$REPO_ROOT" pull --ff-only
    run_cmd bun install
    run_cmd bash "$REPO_ROOT/flow-bar/build-app.sh"
    run_cmd bash "$REPO_ROOT/launchd/install.sh"
    install_qwen3_model
    sync_personal_data
    log "VoiceLayer update complete."
}

main "$@"
