#!/usr/bin/env bash
# VoiceLayer CLI wrapper
# Routes subcommands to the appropriate handler

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FLOW_BAR_DIR="$(cd "$SCRIPT_DIR/../../flow-bar" && pwd)"

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
    bar)
        shift
        echo "[voicelayer] Building Voice Bar..."
        cd "$FLOW_BAR_DIR"
        swift build -c release 2>&1 | tail -1
        echo "[voicelayer] Launching Voice Bar..."
        exec ".build/release/FlowBar" "$@"
        ;;
    bar-stop)
        if pkill -f "FlowBar" 2>/dev/null; then
            echo "[voicelayer] Voice Bar stopped."
        else
            echo "[voicelayer] Voice Bar is not running."
        fi
        ;;
    --help|-h|"")
        echo "Usage: voicelayer <command> [options]"
        echo ""
        echo "Commands:"
        echo "  extract    Extract voice samples from YouTube for voice cloning"
        echo "  clone      Create a voice profile from extracted samples"
        echo "  daemon     Start the TTS daemon (Qwen3-TTS on port 8880)"
        echo "  bar        Build and launch Voice Bar (floating pill widget)"
        echo "  bar-stop   Stop the Voice Bar if running"
        echo ""
        echo "Examples:"
        echo "  voicelayer extract --source 'https://youtube.com/@t3dotgg' --name theo --count 20"
        echo "  voicelayer clone --name theo"
        echo "  voicelayer daemon --port 8880"
        echo "  voicelayer bar"
        echo ""
        echo "Run 'voicelayer <command> --help' for command-specific options."
        ;;
    *)
        echo "Unknown command: $1"
        echo "Run 'voicelayer --help' for usage."
        exit 1
        ;;
esac
