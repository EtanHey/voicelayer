"""
Backend wrappers for STT evaluation.

Each backend implements transcribe(audio_path) -> (text, latency_ms).
Backends are thin wrappers — they invoke the real STT engines.
"""

import os
import subprocess
import time
from dataclasses import dataclass
from typing import Optional, Protocol


class STTBackendProto(Protocol):
    """Protocol for STT evaluation backends."""

    name: str

    def is_available(self) -> bool: ...
    def transcribe(self, audio_path: str, language: str = "he") -> tuple[str, float]: ...


@dataclass
class WhisperCppBackend:
    """
    Whisper.cpp local backend (large-v3-turbo via GGML).

    Binary: whisper-cli or whisper-cpp
    Model: ~/.cache/whisper/ggml-large-v3-turbo.bin (or auto-detected)
    """

    name: str = "whisper-cpp"
    binary_path: Optional[str] = None
    model_path: Optional[str] = None

    def _find_binary(self) -> Optional[str]:
        for name in ["whisper-cli", "whisper-cpp"]:
            try:
                result = subprocess.run(
                    ["which", name], capture_output=True, text=True, timeout=5
                )
                if result.returncode == 0:
                    return result.stdout.strip()
            except (subprocess.TimeoutExpired, FileNotFoundError):
                continue
        return None

    def _find_model(self) -> Optional[str]:
        env_model = os.environ.get("QA_VOICE_WHISPER_MODEL")
        if env_model and os.path.exists(env_model):
            return env_model

        cache_dir = os.path.join(os.path.expanduser("~"), ".cache", "whisper")
        candidates = [
            "ggml-large-v3-turbo.bin",
            "ggml-large-v3-turbo-q5_0.bin",
            "ggml-base.en.bin",
            "ggml-base.bin",
            "ggml-small.en.bin",
            "ggml-small.bin",
        ]
        for name in candidates:
            path = os.path.join(cache_dir, name)
            if os.path.exists(path):
                return path

        if os.path.isdir(cache_dir):
            for f in sorted(os.listdir(cache_dir)):
                if f.startswith("ggml-") and f.endswith(".bin"):
                    return os.path.join(cache_dir, f)

        return None

    def is_available(self) -> bool:
        self.binary_path = self._find_binary()
        self.model_path = self._find_model()
        return self.binary_path is not None and self.model_path is not None

    def transcribe(self, audio_path: str, language: str = "he") -> tuple[str, float]:
        if not self.binary_path:
            self.binary_path = self._find_binary()
        if not self.model_path:
            self.model_path = self._find_model()

        if not self.binary_path or not self.model_path:
            raise RuntimeError("whisper-cpp binary or model not found")

        env = dict(os.environ)
        try:
            brew_result = subprocess.run(
                ["brew", "--prefix", "whisper-cpp"],
                capture_output=True, text=True, timeout=5,
            )
            if brew_result.returncode == 0:
                prefix = brew_result.stdout.strip()
                env["GGML_METAL_PATH_RESOURCES"] = os.path.join(prefix, "share", "whisper-cpp")
        except (subprocess.TimeoutExpired, FileNotFoundError):
            pass

        args = [
            self.binary_path,
            "-m", self.model_path,
            "-f", audio_path,
            "--no-timestamps",
            "-l", language,
            "--no-prints",
        ]

        start = time.perf_counter()
        result = subprocess.run(
            args, capture_output=True, text=True, timeout=120, env=env,
        )
        elapsed_ms = (time.perf_counter() - start) * 1000

        if result.returncode != 0:
            raise RuntimeError(
                f"whisper-cpp failed (exit {result.returncode}): {result.stderr[:500]}"
            )

        text = " ".join(
            line.strip()
            for line in result.stdout.splitlines()
            if line.strip()
        ).strip()

        return text, elapsed_ms

    def get_model_name(self) -> str:
        if self.model_path:
            return os.path.basename(self.model_path)
        return "unknown"


@dataclass
class VoiceLayerBackend:
    """
    VoiceLayer STT backend — uses the project's own Bun-based STT.

    Invokes: bun run src/stt.ts (or the exported transcribe function via CLI wrapper).
    """

    name: str = "voicelayer"
    project_root: Optional[str] = None

    def __post_init__(self):
        if not self.project_root:
            self.project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    def is_available(self) -> bool:
        stt_path = os.path.join(self.project_root or "", "src", "stt.ts")
        return os.path.exists(stt_path)

    def transcribe(self, audio_path: str, language: str = "he") -> tuple[str, float]:
        script = f"""
import {{ WhisperCppBackend }} from "./src/stt.ts";
const backend = new WhisperCppBackend();
const available = await backend.isAvailable();
if (!available) {{ console.log("UNAVAILABLE"); process.exit(0); }}
const result = await backend.transcribe("{audio_path}");
console.log(JSON.stringify({{ text: result.text, durationMs: result.durationMs }}));
"""
        start = time.perf_counter()
        result = subprocess.run(
            ["bun", "eval", script],
            capture_output=True,
            text=True,
            timeout=120,
            cwd=self.project_root,
            env={**os.environ, "QA_VOICE_WHISPER_LANG": language},
        )
        elapsed_ms = (time.perf_counter() - start) * 1000

        if result.returncode != 0:
            raise RuntimeError(f"VoiceLayer STT failed: {result.stderr[:500]}")

        stdout = result.stdout.strip()
        if stdout == "UNAVAILABLE":
            raise RuntimeError("VoiceLayer STT backend unavailable")

        import json
        for line in stdout.splitlines():
            line = line.strip()
            if line.startswith("{"):
                data = json.loads(line)
                return data["text"], data.get("durationMs", elapsed_ms)

        raise RuntimeError(f"Could not parse VoiceLayer output: {stdout[:200]}")


@dataclass
class WisprFlowBackend:
    """
    Wispr Flow cloud backend (requires QA_VOICE_WISPR_KEY).

    NOTE: Wispr Flow stores TEXT ONLY in its local sqlite database.
    There are no local audio blobs — audio is streamed to cloud.
    For eval, we send our generated audio through their API.
    """

    name: str = "wispr-flow"

    def is_available(self) -> bool:
        return bool(os.environ.get("QA_VOICE_WISPR_KEY"))

    def transcribe(self, audio_path: str, language: str = "he") -> tuple[str, float]:
        raise NotImplementedError(
            "Wispr Flow eval requires WebSocket integration. "
            "Use the VoiceLayer Bun-based WisprFlowBackend for live evaluation."
        )


def get_available_backends(project_root: Optional[str] = None) -> list[STTBackendProto]:
    """Return list of available STT backends for evaluation."""
    backends: list[STTBackendProto] = []

    whisper = WhisperCppBackend()
    if whisper.is_available():
        backends.append(whisper)

    voicelayer = VoiceLayerBackend(project_root=project_root)
    if voicelayer.is_available():
        backends.append(voicelayer)

    wispr = WisprFlowBackend()
    if wispr.is_available():
        backends.append(wispr)

    return backends
