"""Private stdio sidecar, owned exclusively by the VoiceBar-owned MCP daemon.

No listener, launch agent, downloads, prompt or audio rewriting. stdout is JSONL;
model diagnostics go to stderr. Importing this file does not import MLX/load a model.
"""
import argparse
import contextlib
import json
import math
import os
from pathlib import Path
import sys
import threading
import time
import wave


class ReturnedDecodeError(ValueError):
    """A provider returned bytes, but they cannot qualify as complete output."""
    def __init__(self, status, attempt):
        super().__init__("Incomplete source coverage or response")
        self.status = status
        self.attempt = attempt


def watch_parent(pid):
    while os.getppid() == pid:
        time.sleep(0.5)
    os._exit(0)  # Never outlive the exact parent that supplied our private pipes.


def read_pcm(path):
    with wave.open(str(path), "rb") as wav:
        if (wav.getnchannels(), wav.getsampwidth(), wav.getframerate(), wav.getcomptype()) != (1, 2, 16000, "NONE"):
            raise ValueError("Expected complete mono 16kHz PCM16 WAV")
        frames = wav.getnframes()
        pcm = wav.readframes(frames)
        if frames <= 0 or len(pcm) != frames * 2:
            raise ValueError("Incomplete WAV")
    return pcm, frames


def decode(model, mx, np, path):
    pcm, frames = read_pcm(path)
    audio = mx.array(np.frombuffer(pcm, dtype="<i2").astype(np.float32) / 32768.0)
    progress = []

    def chunk(end, total):
        if total != frames or not 0 < end <= frames:
            raise ValueError("Invalid source coverage")
        progress.append(end)

    mx.synchronize()
    start = time.monotonic()
    result = model.generate(audio, chunk_duration=30.0, overlap_duration=2.0,
                            stream=False, verbose=False, chunk_callback=chunk)
    mx.synchronize()
    # Callback is before decode; only a returned final result makes it complete.
    covered = progress[-1] if progress else (frames if frames <= 30 * 16000 else 0)
    ends = []
    raw_times = []
    times_valid = True
    for sentence in getattr(result, "sentences", []):
        for token in getattr(sentence, "tokens", []):
            start_time = getattr(token, "start", None)
            end = getattr(token, "end", None)
            valid = (isinstance(start_time, (float, int)) and isinstance(end, (float, int))
                     and math.isfinite(start_time) and math.isfinite(end)
                     and 0 <= start_time <= end <= frames / 16000)
            times_valid = times_valid and valid
            def raw_time(value):
                if value is None or isinstance(value, (str, bool)):
                    return value
                if isinstance(value, (float, int)):
                    return value if math.isfinite(value) else repr(value)
                return {"unrepresentable_type": type(value).__name__}
            raw_times.append({"start": raw_time(start_time), "end": raw_time(end)})
            if isinstance(end, (float, int)) and math.isfinite(end):
                ends.append(float(end))
    text = getattr(result, "text", None)
    complete = covered == frames and isinstance(text, str)
    value = {"text": text if isinstance(text, str) else None, "complete": complete, "input_frames": frames,
            "covered_frames": covered, "sample_rate": 16000,
            "last_token_end_s": max(ends) if ends else None,
            "inference_s": time.monotonic() - start,
            "language": None, "raw_token_times": raw_times,
            "attemptEvidence": {"status": ("RETURNED" if text.strip() else "EMPTY_RESPONSE") if complete else "PARTIAL",
                                "inputPath": str(path), "decodeCoverage": "FULL_INPUT" if covered == frames else "PARTIAL", "tail": "UNKNOWN", "timesValid": times_valid}}
    if not complete:
        # Retain the actual returned hypothesis/times before rejecting it. A
        # coverage failure must not erase data that already crossed the model.
        raise ReturnedDecodeError("PARTIAL" if isinstance(text, str) else "INVALID", value)
    return value


def serve(model, mx, np, source, output):
    for line in source:
        request_id = None
        fatal = False
        try:
            if len(line) > 65536:
                raise ValueError("Oversized command")
            request = json.loads(line)
            request_id = request["id"]
            if type(request_id) is not int or request_id <= 0:
                raise ValueError("Invalid request id")
            op = request["op"]
            if op == "health":
                value = {"ready": True, "protocol": 1, "pid": os.getpid()}
            elif op == "transcribe":
                with contextlib.redirect_stdout(sys.stderr):
                    value = decode(model, mx, np, Path(request["audio_path"]).resolve(strict=True))
            elif op == "shutdown":
                output.write(json.dumps({"id": request_id, "ok": True}) + "\n")
                output.flush()
                return 0
            else:
                raise ValueError("Unknown command")
            response = {"id": request_id, "ok": True, **value}
        except BaseException as error:
            fatal = isinstance(error, (MemoryError, KeyboardInterrupt, SystemExit))
            # No private audio/transcript/exception message is echoed into logs.
            response = {"id": request_id, "ok": False, "code": type(error).__name__, "fatal": fatal}
            if isinstance(error, ReturnedDecodeError):
                response.update({"status": error.status, "attempt": error.attempt})
        output.write(json.dumps(response, allow_nan=False) + "\n")
        output.flush()
        if fatal:
            return 1
    return 0  # EOF means parent closed the private channel.


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--parent-pid", required=True, type=int)
    args = parser.parse_args()
    if os.getppid() != args.parent_pid:
        return 1
    threading.Thread(target=watch_parent, args=(args.parent_pid,), daemon=True).start()
    model_path = Path(args.model).resolve(strict=True)
    # Local assets only: never treat a missing path as a Hub repo/download request.
    for name in ("config.json", "model.safetensors", "tokenizer.model"):
        if not (model_path / name).is_file():
            raise ValueError("Missing local model assets")
    with contextlib.redirect_stdout(sys.stderr):
        import mlx.core as mx
        import numpy as np
        from mlx_audio.stt.utils import load_model
        model = load_model(str(model_path))
        if getattr(getattr(model, "preprocessor_config", None), "sample_rate", None) != 16000:
            raise ValueError("Expected the 16kHz Parakeet model")
        mx.synchronize()
    return serve(model, mx, np, sys.stdin, sys.stdout)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print("Parakeet startup failed: " + type(error).__name__, file=sys.stderr)
        sys.exit(1)
