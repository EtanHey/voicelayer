#!/usr/bin/env bash
# VoiceLayer CLI wrapper
# Routes subcommands to the appropriate handler

set -euo pipefail

# Resolve $0 through symlinks so PACKAGE_ROOT points at the real package even
# when this script is invoked via a bin symlink (`bun add -g`, `npm i -g`, etc).
# `readlink -f` is supported on Linux and macOS 12+; the manual fallback covers
# older macOS without GNU coreutils.
voicelayer_resolve_self() {
    local src="${BASH_SOURCE[0]}"
    local resolved
    if resolved="$(readlink -f "$src" 2>/dev/null)" && [ -n "$resolved" ]; then
        printf '%s\n' "$resolved"
        return
    fi
    while [ -L "$src" ]; do
        local link
        link="$(readlink "$src")" || break
        case "$link" in
            /*) src="$link" ;;
            *)  src="$(cd "$(dirname "$src")" && cd "$(dirname "$link")" && pwd -P)/$(basename "$link")" ;;
        esac
    done
    printf '%s\n' "$src"
}

SCRIPT_PATH="$(voicelayer_resolve_self)"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Debug seam — tests assert symlink resolution by reading this value.
if [[ "${VOICELAYER_DEBUG_PACKAGE_ROOT:-0}" = "1" ]]; then
    printf '%s\n' "$PACKAGE_ROOT"
    exit 0
fi

case "${1:-}" in
    extract)
        shift
        exec python3 "$SCRIPT_DIR/extract.py" "$@"
        ;;
    clone)
        shift
        exec python3 "$SCRIPT_DIR/clone.py" "$@"
        ;;
    daemon)
        shift
        exec python3 "$SCRIPT_DIR/../tts_daemon.py" "$@"
        ;;
    serve)
        shift
        exec bun "$SCRIPT_DIR/../daemon.ts" "$@"
        ;;
    vocab)
        shift
        exec bun "$SCRIPT_DIR/vocab.ts" "$@"
        ;;
    update)
        shift
        exec bash "$PACKAGE_ROOT/scripts/voicelayer-update.sh" "$@"
        ;;
    build-app)
        shift
        exec bash "$PACKAGE_ROOT/flow-bar/build-app.sh" "$@"
        ;;
    setup)
        shift
        exec bun "$SCRIPT_DIR/setup.ts" "$PACKAGE_ROOT" "$@"
        ;;
    bar)
        shift
        if [[ ! -d "/Applications/VoiceBar.app" ]]; then
            echo "[voicelayer] VoiceBar.app is not installed. Run: voicelayer build-app" >&2
            exit 1
        fi
        echo "[voicelayer] Launching /Applications/VoiceBar.app..."
        exec open "/Applications/VoiceBar.app" --args "$@"
        ;;
    hotkey)
        shift
        case "${1:-install}" in
            install)
                exec "$PACKAGE_ROOT/scripts/install-voicebar-f5-hidutil.sh"
                ;;
            status)
                launchctl print "gui/$(id -u)/com.voicelayer.f5-to-f18-hidutil" 2>/dev/null || true
                hidutil property --get UserKeyMapping
                ;;
            *)
                echo "Usage: voicelayer hotkey [install|status]"
                exit 1
                ;;
        esac
        ;;
    autostart)
        shift
        case "${1:-install}" in
            install)
                exec "$PACKAGE_ROOT/scripts/install-voicebar-autostart.sh"
                ;;
            status)
                label="com.voicelayer.voicebar"
                plist="$HOME/Library/LaunchAgents/$label.plist"
                if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
                    state="loaded"
                else
                    state="notloaded"
                fi
                printf '%s %s\n' "$label" "$state"
                printf 'path: %s\n' "$plist"
                ;;
            *)
                echo "Usage: voicelayer autostart [install|status]"
                exit 1
                ;;
        esac
        ;;
    bar-stop)
        if pkill -f "VoiceBar" 2>/dev/null; then
            echo "[voicelayer] Voice Bar stopped."
        else
            echo "[voicelayer] Voice Bar is not running."
        fi
        ;;
    --help|-h|"")
        echo "Usage: voicelayer <command> [options]"
        echo ""
        echo "Commands:"
        echo "  serve      Start standalone voice daemon (without MCP/Claude Code)"
        echo "  extract    Extract voice samples from YouTube for voice cloning"
        echo "  clone      Create a voice profile from extracted samples"
        echo "  daemon     Start the TTS daemon (Qwen3-TTS on port 8880)"
        echo "  build-app  Build and install /Applications/VoiceBar.app"
        echo "  setup      Install VoiceLayer, wire MCP, and guide macOS permissions"
        echo "  bar        Launch VoiceBar.app (floating pill widget)"
        echo "  vocab      Add, list, or remove STT vocabulary aliases"
        echo "  update     Update app, daemon, model, and personal VoiceLayer data"
        echo "  autostart  Install or inspect the VoiceBar login LaunchAgent"
        echo "  hotkey     Install or inspect the F5/Dictation hotkey relay"
        echo "  bar-stop   Stop the Voice Bar if running"
        echo ""
        echo "Examples:"
        echo "  voicelayer extract --source 'https://youtube.com/@t3dotgg' --name theo --count 20"
        echo "  voicelayer clone --name theo"
        echo "  voicelayer daemon --port 8880"
        echo "  voicelayer setup"
        echo "  voicelayer build-app"
        echo "  voicelayer bar"
        echo "  voicelayer vocab add --wrong 'domekin' --right 'Domica'"
        echo "  voicelayer update --dry-run"
        echo "  voicelayer autostart install"
        echo "  voicelayer hotkey install"
        echo ""
        echo "Run 'voicelayer <command> --help' for command-specific options."
        ;;
    *)
        echo "Unknown command: $1"
        echo "Run 'voicelayer --help' for usage."
        exit 1
        ;;
esac
