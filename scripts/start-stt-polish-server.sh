#!/usr/bin/env bash
set -euo pipefail

MODEL="${QA_VOICE_STT_POLISH_MODEL:-mlx-community/Qwen3-4B-Instruct-2507-4bit}"
HOST="${QA_VOICE_STT_POLISH_HOST:-127.0.0.1}"
PORT="${QA_VOICE_STT_POLISH_PORT:-8080}"

if ! command -v mlx_lm.server >/dev/null 2>&1; then
  cat >&2 <<'EOF'
mlx_lm.server not found.

Install the local MLX server first:
  uv tool install mlx-lm

Then rerun this script.
EOF
  exit 127
fi

printf 'Starting VoiceLayer STT polish server\n' >&2
printf '  model: %s\n' "$MODEL" >&2
printf '  url:   http://%s:%s/v1/chat/completions\n' "$HOST" "$PORT" >&2

exec mlx_lm.server \
  --model "$MODEL" \
  --host "$HOST" \
  --port "$PORT"
