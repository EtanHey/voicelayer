import { expect, test } from "bun:test";

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
});
