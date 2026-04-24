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
import hmac
import logging
import os
import secrets
import sys
import time
from pathlib import Path
from typing import Mapping

logging.basicConfig(level=logging.INFO, format="[tts-daemon] %(message)s")
logger = logging.getLogger("tts-daemon")

DEFAULT_MODEL_PATH = Path.home() / ".voicelayer" / "models" / "qwen3-tts-4bit"
DEFAULT_AUTH_TOKEN_FILE = Path.home() / ".voicelayer" / "daemon.secret"
DEFAULT_VOICES_DIR = Path.home() / ".voicelayer" / "voices"
DEFAULT_PORT = 8880
MAX_REFERENCE_WAV_BYTES = 5 * 1024 * 1024  # 24kHz mono PCM WAV, comfortably >60s


def resolve_auth_token_file(token_file: str | None = None) -> Path:
    """Resolve the daemon bearer token file from CLI/env/defaults."""
    raw = (
        token_file
        or os.environ.get("VOICELAYER_TTS_DAEMON_SECRET_FILE")
        or os.environ.get("VOICELAYER_TTS_AUTH_TOKEN_FILE")
    )
    if raw:
        return Path(raw).expanduser()
    return DEFAULT_AUTH_TOKEN_FILE


def ensure_private_directory(directory: Path, mode: int) -> Path:
    """Create or tighten a private directory used by the daemon."""
    directory.mkdir(parents=True, exist_ok=True, mode=mode)
    os.chmod(directory, mode)
    return directory


def ensure_bearer_token_file(token_file: Path) -> str:
    """Create or load the bearer token from a strict 0600 file."""
    ensure_private_directory(token_file.parent, 0o700)

    if token_file.is_symlink():
        raise ValueError(f"Auth token file must not be a symlink: {token_file}")

    if not token_file.exists():
        fd = os.open(token_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(f"{secrets.token_hex(32)}\n")

    os.chmod(token_file, 0o600)

    token = token_file.read_text(encoding="utf-8").strip()
    if not token:
        raise ValueError(f"Auth token file is empty: {token_file}")
    return token


def build_allowed_hosts(port: int) -> set[str]:
    """Allowed Host header values for this daemon instance."""
    return {
        f"127.0.0.1:{port}",
        f"localhost:{port}",
    }


def build_allowed_origins(port: int) -> set[str]:
    """Allowed Origin header values for browser requests."""
    return {
        "null",
        f"http://127.0.0.1:{port}",
        f"http://localhost:{port}",
    }


def enforce_local_request(
    headers: Mapping[str, str],
    allowed_hosts: set[str],
    allowed_origins: set[str],
) -> None:
    """Reject requests that do not target the local daemon allowlist."""
    host = headers.get("host", "").strip().lower()
    if host not in allowed_hosts:
        raise PermissionError(
            "Host header must target the configured localhost daemon."
        )

    origin = headers.get("origin")
    if origin and origin.strip().lower() not in allowed_origins:
        raise PermissionError("Origin header is not allowed for this daemon.")


def is_valid_bearer_auth(authorization: str | None, expected_token: str) -> bool:
    """Constant-time bearer token validation."""
    if not authorization or not authorization.startswith("Bearer "):
        return False
    presented = authorization[len("Bearer ") :].strip()
    if not presented:
        return False
    return hmac.compare_digest(presented, expected_token)


def validate_reference_wav_path(
    reference_wav: str, voices_root: Path = DEFAULT_VOICES_DIR
) -> Path:
    """Allow only reference audio that resolves inside ~/.voicelayer/voices."""
    requested = Path(reference_wav).expanduser()
    resolved = requested.resolve(strict=False)
    voices_root_resolved = voices_root.expanduser().resolve(strict=False)

    if not resolved.is_relative_to(voices_root_resolved):
        raise PermissionError(
            f"Reference audio must live under {voices_root_resolved}."
        )

    if requested.suffix.lower() != ".wav":
        raise ValueError("Reference audio must be a .wav file.")

    if not resolved.exists():
        raise FileNotFoundError("Reference audio not found.")

    if not resolved.is_file():
        raise ValueError("Reference audio must be a regular file.")

    stats = resolved.stat()
    if stats.st_size > MAX_REFERENCE_WAV_BYTES:
        raise ValueError(
            f"Reference audio exceeds {MAX_REFERENCE_WAV_BYTES // (1024 * 1024)} MB."
        )

    return resolved


def create_app(
    model_path: str = str(DEFAULT_MODEL_PATH),
    host: str = "127.0.0.1",
    port: int = DEFAULT_PORT,
    auth_token_file: str | None = None,
    voices_root: str = str(DEFAULT_VOICES_DIR),
):
    """Create FastAPI app with model loaded."""
    try:
        from fastapi import FastAPI, HTTPException, Request
        from fastapi.middleware.cors import CORSMiddleware
        from pydantic import BaseModel
    except ImportError:
        logger.error("FastAPI not installed. Run: pip install fastapi uvicorn")
        sys.exit(1)

    try:
        import mlx_audio
    except ImportError:
        logger.error("mlx-audio not installed. Run: pip install mlx-audio")
        sys.exit(1)

    token_file = resolve_auth_token_file(auth_token_file)
    try:
        auth_token = ensure_bearer_token_file(token_file)
    except Exception as exc:
        logger.critical(
            "FATAL: failed to load daemon secret from %s: %s",
            token_file,
            exc,
        )
        sys.exit(1)

    voices_root_path = Path(voices_root).expanduser()
    try:
        voices_root_path = ensure_private_directory(voices_root_path, 0o700)
    except Exception as exc:
        logger.critical(
            "FATAL: failed to prepare voices directory %s: %s",
            voices_root_path,
            exc,
        )
        sys.exit(1)

    allowed_hosts = build_allowed_hosts(port)
    allowed_origins = build_allowed_origins(port)

    app = FastAPI(title="VoiceLayer TTS Daemon", version="1.0.0")
    app.add_middleware(
        CORSMiddleware,
        allow_origins=[],
        allow_credentials=False,
        allow_methods=["GET", "POST"],
        allow_headers=["Authorization", "Content-Type"],
    )
    logger.info(f"Using bearer auth token file {token_file}")

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

    def guard_request(request: Request) -> None:
        try:
            enforce_local_request(
                request.headers,
                allowed_hosts,
                allowed_origins,
            )
        except PermissionError as exc:
            raise HTTPException(403, str(exc)) from exc

        if not is_valid_bearer_auth(
            request.headers.get("authorization"), auth_token
        ):
            raise HTTPException(
                401,
                "Bearer token required.",
                headers={"WWW-Authenticate": "Bearer"},
            )

    @app.post("/synthesize", response_model=SynthesizeResponse)
    async def synthesize(req: SynthesizeRequest, request: Request):
        """Synthesize speech using a bearer-authenticated WAV under ~/.voicelayer/voices/."""
        guard_request(request)

        if model is None:
            raise HTTPException(503, "Model not loaded. Check daemon logs.")

        if not req.text.strip():
            raise HTTPException(400, "text must not be empty")

        try:
            ref_path = validate_reference_wav_path(
                req.reference_wav,
                voices_root=voices_root_path,
            )
        except FileNotFoundError as exc:
            raise HTTPException(400, str(exc)) from exc
        except PermissionError as exc:
            raise HTTPException(403, str(exc)) from exc
        except ValueError as exc:
            raise HTTPException(400, str(exc)) from exc

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
    async def health(request: Request):
        guard_request(request)

        return {
            "status": "ok" if model is not None else "no_model",
            "model_path": str(model_path),
            "model_loaded": model is not None,
            "model_load_time_s": model_load_time,
            "pid": os.getpid(),
        }

    @app.post("/warmup")
    async def warmup(request: Request):
        """Pre-warm model with a short synthesis (Metal shader compilation)."""
        guard_request(request)

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
    parser.add_argument(
        "--daemon-secret-file",
        "--auth-token-file",
        type=str,
        default=None,
        dest="auth_token_file",
        help=(
            "Bearer secret file shared with the TypeScript bridge "
            f"(default: {DEFAULT_AUTH_TOKEN_FILE})"
        ),
    )
    args = parser.parse_args()

    try:
        import uvicorn
    except ImportError:
        logger.error("uvicorn not installed. Run: pip install uvicorn")
        sys.exit(1)

    app = create_app(
        args.model,
        host=args.host,
        port=args.port,
        auth_token_file=args.auth_token_file,
    )
    logger.info(f"Starting TTS daemon on {args.host}:{args.port}")
    uvicorn.run(app, host=args.host, port=args.port, log_level="warning")


if __name__ == "__main__":
    main()
