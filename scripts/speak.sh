#!/bin/bash
# speak.sh — Standalone TTS command for QA Voice
#
# Usage: ./scripts/speak.sh "Hello, how are you?"
#        ./scripts/speak.sh "Hello" "-5%"    # with rate override
#        echo "text" | ./scripts/speak.sh
#
# Uses Python edge-tts CLI + afplay (matches MCP server tts.ts).

VOICE="${QA_VOICE_TTS_VOICE:-en-US-JennyNeural}"
RATE="${QA_VOICE_TTS_RATE:-+0%}"
TTS_FILE="/tmp/voicelayer-tts-$$.mp3"

# Get text from args or stdin
if [ $# -gt 0 ]; then
    TEXT="$1"
    # Optional second arg overrides rate
    if [ -n "$2" ]; then
        RATE="$2"
    fi
elif [ ! -t 0 ]; then
    TEXT="$(cat)"
else
    echo "Usage: speak.sh <text> [rate]" >&2
    echo "  rate: e.g. \"+15%\", \"-5%\", \"+0%\" (default: \$QA_VOICE_TTS_RATE or +15%)" >&2
    exit 1
fi

if [ -z "$TEXT" ]; then
    echo "No text provided." >&2
    exit 1
fi

# Synthesize via Python edge-tts CLI
if ! python3 -m edge_tts --text "$TEXT" --voice "$VOICE" --rate "$RATE" --write-media "$TTS_FILE" 2>/dev/null; then
    echo "[speak.sh] edge-tts failed. Is it installed? Run: pip3 install edge-tts" >&2
    exit 1
fi

# Play audio
afplay "$TTS_FILE" 2>/dev/null
rm -f "$TTS_FILE"
