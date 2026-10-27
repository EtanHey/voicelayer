import json
import os
import socket
import sys
import time
from pathlib import Path
from types import SimpleNamespace

root = Path(sys.argv[1])
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src"))
from tts_daemon import create_app


class StepModel:
    def step(self, text):
        time.sleep(0.02)
        with (root / f"steps-{text}").open("a") as output:
            output.write("step\n")

    def _sample_token(self, text):
        self.step(text)

    def generate(self, text, **kwargs):
        (root / f"started-{text}").touch()
        try:
            if text == "error":
                raise RuntimeError("stub generation failed")
            if text == "segments":
                for _ in range(300):
                    self.step(text)
                    yield b"stub-mp3"
                return
            for _ in range(300 if text in {"slow", "queued"} else 2):
                self._sample_token(text)
            yield b"stub-mp3"
        finally:
            (root / f"closed-{text}").touch()


def generate_audio(model, text, output_path, **kwargs):
    with (root / "output-dirs").open("a") as output:
        output.write(output_path + "\n")
    try:
        result = b"".join(model.generate(text=text))
    except Exception:
        return
    (Path(output_path) / "synthesis.mp3").write_bytes(result)


sys.modules.update({
    "mlx_audio": SimpleNamespace(),
    "mlx_audio.tts": SimpleNamespace(),
    "mlx_audio.tts.utils": SimpleNamespace(load=lambda _: StepModel()),
    "mlx_audio.tts.generate": SimpleNamespace(generate_audio=generate_audio),
})
os.environ["VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS"] = "600"
sample = root / "voices" / "clip.wav"
sample.parent.mkdir(parents=True)
sample.write_bytes(b"RIFF")
listener = socket.socket()
listener.bind(("127.0.0.1", 0))
port = listener.getsockname()[1]
app = create_app("stub", port=port, auth_token_file=str(root / "secret"),
                 voices_root=str(sample.parent))
(root / "ready.json").write_text(json.dumps({"port": port}))
import uvicorn

uvicorn.Server(uvicorn.Config(app, log_level="error")).run(sockets=[listener])
