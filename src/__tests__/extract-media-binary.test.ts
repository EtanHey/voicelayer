import { expect, test } from "bun:test";

// Real subprocesses: standalone p95 <= 80 ms; 4x rounded up, with a 5 s scheduling floor.
const SUBPROCESS_TEST_TIMEOUT_MS = 5_000;

test("Python extraction validates media binaries, caches success, and normalizes with the resolved path", () => {
  const result = Bun.spawnSync(["python3", "-c", `
import importlib.util, unittest.mock as mock, subprocess
from pathlib import Path
spec = importlib.util.spec_from_file_location("extract", "src/cli/extract.py")
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
calls = []
def run(argv, **kwargs):
    calls.append(argv)
    if argv[0] == "/stale/ffmpeg": raise OSError(86, "Bad CPU type")
    return subprocess.CompletedProcess(argv, 0 if argv[0] == "/working/ffmpeg" else 1, "", "")
with mock.patch.dict("os.environ", {"PATH": "/stale:/working"}), mock.patch("subprocess.run", side_effect=run), mock.patch("platform.machine", return_value="x86_64"):
    assert module.resolve_media_binary("ffmpeg") == "/working/ffmpeg"
    count = len(calls)
    assert module.resolve_media_binary("ffmpeg") == "/working/ffmpeg"
    assert len(calls) == count
    assert module.normalize_audio(Path("in.wav"), Path("out.wav"))
    assert calls[-1][0] == "/working/ffmpeg"
    assert ["/stale/ffmpeg", "-version"] in calls
`], {stdout: "pipe", stderr: "pipe"});
  expect(result.stderr.toString()).toBe("");
  expect(result.exitCode).toBe(0);
}, SUBPROCESS_TEST_TIMEOUT_MS);


test("yt-dlp receives both independently resolved media executables for the entire download", () => {
  const result = Bun.spawnSync(["python3", "-c", `
import importlib.util, unittest.mock as mock, subprocess, tempfile
from pathlib import Path
spec = importlib.util.spec_from_file_location("extract", "src/cli/extract.py")
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
with tempfile.TemporaryDirectory() as root:
    root = Path(root)
    a, b = root / "a", root / "b"
    a.mkdir(); b.mkdir()
    ffmpeg, ffprobe = a / "ffmpeg", b / "ffprobe"
    ffmpeg.write_text("working ffmpeg"); ffprobe.write_text("working ffprobe")
    paths = {"ffmpeg": str(ffmpeg), "ffprobe": str(ffprobe)}
    locations = []
    def run(argv, **kwargs):
        location = Path(argv[argv.index("--ffmpeg-location") + 1])
        locations.append(location)
        assert (location / "ffmpeg").resolve() == ffmpeg.resolve()
        assert (location / "ffprobe").resolve() == ffprobe.resolve()
        assert (location / "ffprobe").is_file()
        return subprocess.CompletedProcess(argv, 0, "", "")
    with mock.patch.object(module, "resolve_media_binary", side_effect=paths.__getitem__), mock.patch("subprocess.run", side_effect=run):
        module.download_audio("fixture://source", root / "output", root / "archive.txt", 1)
    assert len(locations) == 1
    assert not locations[0].exists()
    assert ffmpeg.is_file() and ffprobe.is_file()
`], {stdout:"pipe", stderr:"pipe"});
  expect(result.stderr.toString()).toBe("");
  expect(result.exitCode).toBe(0);
}, SUBPROCESS_TEST_TIMEOUT_MS);
