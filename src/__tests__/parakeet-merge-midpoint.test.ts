import { expect, test } from "bun:test";
import { join } from "path";

test("V32 audit midpoint keeps one of two agreeing copies of the straddling word", async () => {
  const proc = Bun.spawn(["python3", "-B", "-c", `
import importlib.util, pathlib, sys, json
root = pathlib.Path(sys.argv[1])
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module
alignment = load('midpoint_alignment', root / '__tests__/fixtures/mlx-audio-0.6.3/alignment.py')
bridge_path = root / 'parakeet_merge_bridge.py'
if bridge_path.exists():
    load('midpoint_bridge', bridge_path).apply_alignment_bridge(alignment)
counts = []
for name in ('merge_longest_contiguous', 'merge_longest_common_subsequence'):
    a = [alignment.AlignedToken(id=1922, text=' word', start=2268.24, duration=.32)]
    b = [alignment.AlignedToken(id=1922, text=' word', start=2268.24, duration=.32)]
    counts.append(len(getattr(alignment, name)(a, b, overlap_duration=2.0)))
print(json.dumps(counts))
`, join(import.meta.dir, "..")], { env: process.env, stdout: "pipe", stderr: "pipe" });
  const [stdout, stderr, code] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
  expect(code).toBe(0); expect(stderr).toBe("");
  expect(JSON.parse(stdout)).toEqual([1, 1]);
});
