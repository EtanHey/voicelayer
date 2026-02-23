#!/usr/bin/env python3
"""
VoiceLayer TTS Daemon — Qwen3-TTS zero-shot voice cloning via MLX.

FastAPI server on port 8880. Loads Qwen3-TTS 0.6B (4-bit MLX quantized) once,
keeps model hot in Metal/MPS memory for fast inference.

Endpoints:
  POST /synthesize  — Generate speech from text + reference audio (cloned voice)
  GET  /health      — Health check + model status
  POST /warmup      — Pre-warm model with a short synthesis

Requirements:
  pip install mlx-audio fastapi uvicorn pyyaml

Usage:
  python3 src/tts_daemon.py                    # default model path
  python3 src/tts_daemon.py --model /path/to   # custom model path
  python3 src/tts_daemon.py --port 8880        # custom port
"""

# AIDEV-NOTE: This daemon runs as a separate process from the MCP server.
# TypeScript side calls it over HTTP (src/tts/qwen3.ts).
# Model stays loaded in memory (~300MB) for fast inference (200-500ms).

import argparse
import base64
import io
import logging
import os
import sys
import time
from pathlib import Path

logging.basicConfig(level=logging.INFO, format="[tts-daemon] %(message)s")
logger = logging.getLogger("tts-daemon")

DEFAULT_MODEL_PATH = Path.home() / ".voicelayer" / "models" / "qwen3-tts-4bit"
DEFAULT_PORT = 8880


def create_app(model_path: str):
    """Create FastAPI app with model loaded."""
    try:
        from fastapi import FastAPI, HTTPException
        from fastapi.responses import JSONResponse
        from pydantic import BaseModel
    except ImportError:
        logger.error("FastAPI not installed. Run: pip install fastapi uvicorn")
        sys.exit(1)

    try:
        import mlx_audio
    except ImportError:
        logger.error("mlx-audio not installed. Run: pip install mlx-audio")
        sys.exit(1)

    app = FastAPI(title="VoiceLayer TTS Daemon", version="1.0.0")

    # --- Model loading ---
    model = None
    model_load_time = None

    class SynthesizeRequest(BaseModel):
        text: str
        reference_wav: str  # path to 24kHz mono 16-bit PCM WAV
        reference_text: str  # transcript of the reference audio

    class SynthesizeResponse(BaseModel):
        audio_b64: str  # base64-encoded MP3
        duration_ms: float

    @app.on_event("startup")
    async def load_model():
        nonlocal model, model_load_time
        logger.info(f"Loading model from {model_path}...")
        start = time.time()
        try:
            model = mlx_audio.load(model_path)
            model_load_time = time.time() - start
            logger.info(f"Model loaded in {model_load_time:.1f}s")
        except Exception as e:
            logger.error(f"Failed to load model: {e}")
            logger.error(
                "Download and quantize first:\n"
                "  python3 -m mlx_audio.quantize \\\n"
                '    --model "Qwen/Qwen3-TTS" \\\n'
                "    --q-bits 4 \\\n"
                f"    --out-path {model_path}"
            )
            # Don't exit — let health check report the error
            model = None

    @app.post("/synthesize", response_model=SynthesizeResponse)
    async def synthesize(req: SynthesizeRequest):
        if model is None:
            raise HTTPException(503, "Model not loaded. Check daemon logs.")

        if not req.text.strip():
            raise HTTPException(400, "text must not be empty")

        ref_path = Path(req.reference_wav).expanduser()
        if not ref_path.exists():
            raise HTTPException(400, f"Reference audio not found: {req.reference_wav}")

        start = time.time()
        try:
            # Generate speech using zero-shot cloning
            audio = model.generate(
                text=req.text,
                reference_audio=str(ref_path),
                reference_text=req.reference_text,
            )

            # Convert to MP3 bytes
            mp3_bytes = audio.to_bytes(format="mp3")
            audio_b64 = base64.b64encode(mp3_bytes).decode("ascii")

            duration_ms = (time.time() - start) * 1000
            logger.info(
                f"Synthesized {len(req.text)} chars in {duration_ms:.0f}ms"
            )

            return SynthesizeResponse(
                audio_b64=audio_b64,
                duration_ms=duration_ms,
            )
        except Exception as e:
            logger.error(f"Synthesis failed: {e}")
            raise HTTPException(500, f"Synthesis failed: {str(e)}")

    @app.get("/health")
    async def health():
        return {
            "status": "ok" if model is not None else "no_model",
            "model_path": str(model_path),
            "model_loaded": model is not None,
            "model_load_time_s": model_load_time,
            "pid": os.getpid(),
        }

    @app.post("/warmup")
    async def warmup():
        """Pre-warm model with a short synthesis (Metal shader compilation)."""
        if model is None:
            raise HTTPException(503, "Model not loaded")

        # Find any WAV file to use as reference for warmup
        # This is just to trigger Metal compilation, output is discarded
        return {"status": "warmup_skipped", "reason": "no reference audio for warmup"}

    return app


def main():
    parser = argparse.ArgumentParser(description="VoiceLayer TTS Daemon")
    parser.add_argument(
        "--model",
        type=str,
        default=str(DEFAULT_MODEL_PATH),
        help=f"Path to quantized Qwen3-TTS model (default: {DEFAULT_MODEL_PATH})",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=DEFAULT_PORT,
        help=f"Port to listen on (default: {DEFAULT_PORT})",
    )
    parser.add_argument(
        "--host",
        type=str,
        default="127.0.0.1",
        help="Host to bind to (default: 127.0.0.1)",
    )
    args = parser.parse_args()

    try:
        import uvicorn
    except ImportError:
        logger.error("uvicorn not installed. Run: pip install uvicorn")
        sys.exit(1)

    app = create_app(args.model)
    logger.info(f"Starting TTS daemon on {args.host}:{args.port}")
    uvicorn.run(app, host=args.host, port=args.port, log_level="warning")


if __name__ == "__main__":
    main()
