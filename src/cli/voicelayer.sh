#!/usr/bin/env bash
# VoiceLayer CLI wrapper
# Routes subcommands to the appropriate handler

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-}" in
    extract)
        shift
        exec python3 "$SCRIPT_DIR/extract.py" "$@"
        ;;
    --help|-h|"")
        echo "Usage: voicelayer <command> [options]"
        echo ""
        echo "Commands:"
        echo "  extract    Extract voice samples from YouTube for voice cloning"
        echo ""
        echo "Examples:"
        echo "  voicelayer extract --source 'https://youtube.com/@t3dotgg' --name theo --count 20"
        echo ""
        echo "Run 'voicelayer <command> --help' for command-specific options."
        ;;
    *)
        echo "Unknown command: $1"
        echo "Run 'voicelayer --help' for usage."
        exit 1
        ;;
esac
